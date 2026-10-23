import 'dart:async';

import '../core/config/app_config.dart';
import '../core/errors/app_exception.dart';
import '../core/protocol/envelope.dart';
import '../core/settings/settings_service.dart';
import '../core/utils/clock.dart';
import '../core/utils/ids.dart';
import '../crypto/identity_holder.dart';
import '../crypto/identity_record.dart';
import '../domain/repositories/identity_repository.dart';
import '../friends/friend_service.dart';
import 'bundle_outbox.dart';
import 'signed_bundle.dart';

/// Consent handshake for changing a conversation's shared retention mode.
///
/// Every phase is idempotent and persisted before its next envelope is queued.
/// The local mode and pending phase share one settings row, making each local
/// transition atomic. A lost control bundle remains in the store-and-forward
/// queue and can be safely delivered again.
class RetentionService {
  RetentionService({
    required SettingsService settings,
    required BundleOutbox outbox,
    required IdentityRepository identities,
    required FriendService friends,
    required IdentityHolder identityHolder,
    required Clock clock,
    required AppConfig config,
  }) : _settings = settings,
       _outbox = outbox,
       _identities = identities,
       _friends = friends,
       _identityHolder = identityHolder,
       _clock = clock,
       _config = config;

  final SettingsService _settings;
  final BundleOutbox _outbox;
  final IdentityRepository _identities;
  final FriendService _friends;
  final IdentityHolder _identityHolder;
  final Clock _clock;
  final AppConfig _config;
  final StreamController<String> _changes = StreamController.broadcast();

  Stream<String> get changes => _changes.stream;

  Future<DisappearingPreferenceState> stateFor(String peerId) =>
      _settings.disappearingStateFor(peerId);

  /// Replays any handshake phase that was persisted just before a shutdown.
  /// Duplicate protocol messages are idempotent by request id.
  Future<void> retryPendingChanges() async {
    final states = await _settings.allDisappearingStates();
    for (final entry in states.entries) {
      final peer = await _identities.find(entry.key);
      if (peer == null) continue;
      final state = entry.value;
      try {
        if (state.outgoingRequestId != null && state.outgoingEnabled != null) {
          if (state.outgoingActivateSent) {
            await _enqueue(
              peer: peer.record,
              type: EnvelopeType.retentionActivate,
              payload: {'rid': state.outgoingRequestId},
            );
          } else if (state.outgoingCommitSent) {
            await _enqueue(
              peer: peer.record,
              type: EnvelopeType.retentionCommit,
              payload: {
                'rid': state.outgoingRequestId,
                'enabled': state.outgoingEnabled,
              },
            );
          } else {
            await _enqueue(
              peer: peer.record,
              type: EnvelopeType.retentionRequest,
              payload: {
                'rid': state.outgoingRequestId,
                'enabled': state.outgoingEnabled,
              },
            );
          }
        }
        if (state.incomingRequestId != null &&
            state.incomingAccepted) {
          if (state.lastAppliedRequestId == state.incomingRequestId) {
            await _enqueue(
              peer: peer.record,
              type: EnvelopeType.retentionCommitAck,
              payload: {'rid': state.incomingRequestId},
            );
          } else {
            await _enqueue(
              peer: peer.record,
              type: EnvelopeType.retentionResponse,
              payload: {'rid': state.incomingRequestId, 'accepted': true},
            );
          }
        }
      } catch (_) {
        // A temporarily unavailable identity or local storage failure must
        // not prevent other conversations from recovering their state.
      }
    }
  }

  Future<void> requestChange({
    required IdentityRecord peer,
    required bool enabled,
  }) async {
    final state = await stateFor(peer.identityId);
    if (state.enabled == enabled) return;
    if (state.outgoingRequestId != null || state.incomingRequestId != null) {
      throw const StateTransitionException(
        'A message-retention change is already awaiting a decision',
      );
    }
    final requestId = Ids.newUuid();
    await _settings.saveDisappearingState(
      peer.identityId,
      state.copyWith(
        outgoingRequestId: requestId,
        outgoingEnabled: enabled,
      ),
    );
    try {
      await _enqueue(
        peer: peer,
        type: EnvelopeType.retentionRequest,
        payload: {'rid': requestId, 'enabled': enabled},
      );
    } catch (_) {
      await _settings.saveDisappearingState(peer.identityId, state);
      rethrow;
    }
    _changes.add(peer.identityId);
  }

  Future<void> handleIncoming(OpenedBundle opened) async {
    final senderId = opened.sender.identityId;
    final state = await stateFor(senderId);
    final payload = opened.payload;
    final requestId = payload['rid'];
    if (requestId is! String || requestId.length > 64) return;

    switch (opened.type) {
      case EnvelopeType.retentionRequest:
        final enabled = payload['enabled'];
        if (enabled is! bool) return;
        if (state.incomingRequestId == requestId &&
            state.incomingEnabled == enabled) {
          if (state.incomingAccepted) {
            if (state.lastAppliedRequestId == requestId) {
              await _enqueue(
                peer: opened.sender,
                type: EnvelopeType.retentionCommitAck,
                payload: {'rid': requestId},
              );
            } else {
              await _enqueue(
                peer: opened.sender,
                type: EnvelopeType.retentionResponse,
                payload: {'rid': requestId, 'accepted': true},
              );
            }
          }
          return;
        }
        if (state.lastRejectedRequestId == requestId) {
          await _enqueue(
            peer: opened.sender,
            type: EnvelopeType.retentionResponse,
            payload: {'rid': requestId, 'accepted': false},
          );
          return;
        }
        if (enabled == state.enabled ||
            state.lastAppliedRequestId == requestId) {
          return;
        }
        if (state.incomingRequestId != null || state.outgoingRequestId != null) {
          return;
        }
        await _settings.saveDisappearingState(
          senderId,
          state.copyWith(
            incomingRequestId: requestId,
            incomingEnabled: enabled,
          ),
        );
        _changes.add(senderId);
      case EnvelopeType.retentionResponse:
        if (state.outgoingRequestId != requestId ||
            state.outgoingEnabled == null ||
            state.outgoingCommitSent) {
          return;
        }
        if (payload['accepted'] != true) {
          await _enqueue(
            peer: opened.sender,
            type: EnvelopeType.retentionResponse,
            payload: {'rid': requestId, 'accepted': false},
          );
          await _settings.saveDisappearingState(
            senderId,
            state.copyWith(clearOutgoing: true),
          );
          _changes.add(senderId);
          return;
        }
        // Queue commit before atomically publishing the mode locally. If the
        // write fails, the repeated response can safely enqueue another commit.
        final enabled = state.outgoingEnabled!;
        await _enqueue(
          peer: opened.sender,
          type: EnvelopeType.retentionCommit,
          payload: {'rid': requestId, 'enabled': enabled},
        );
        await _settings.saveDisappearingState(
          senderId,
          state.copyWith(enabled: enabled, outgoingCommitSent: true),
        );
        _changes.add(senderId);
      case EnvelopeType.retentionCommit:
        final enabled = payload['enabled'];
        if (enabled is! bool) return;
        if (state.lastAppliedRequestId == requestId) {
          await _sendCommitAck(opened.sender, requestId);
          return;
        }
        if (state.incomingRequestId != requestId ||
            !state.incomingAccepted ||
            state.incomingEnabled != enabled) {
          return;
        }
        await _settings.saveDisappearingState(
          senderId,
          state.copyWith(
            enabled: enabled,
            lastAppliedRequestId: requestId,
          ),
        );
        await _sendCommitAck(opened.sender, requestId);
        _changes.add(senderId);
      case EnvelopeType.retentionCommitAck:
        if (state.outgoingRequestId == requestId &&
            state.outgoingCommitSent) {
          await _settings.saveDisappearingState(
            senderId,
            state.copyWith(outgoingActivateSent: true),
          );
          await _enqueue(
            peer: opened.sender,
            type: EnvelopeType.retentionActivate,
            payload: {'rid': requestId},
          );
          _changes.add(senderId);
        }
      case EnvelopeType.retentionActivate:
        if (state.lastAppliedRequestId == requestId &&
            state.incomingRequestId == null) {
          await _enqueue(
            peer: opened.sender,
            type: EnvelopeType.retentionActivateAck,
            payload: {'rid': requestId},
          );
          return;
        }
        if (state.incomingRequestId == requestId &&
            state.incomingAccepted &&
            state.lastAppliedRequestId == requestId) {
          await _settings.saveDisappearingState(
            senderId,
            state.copyWith(clearIncoming: true),
          );
          await _enqueue(
            peer: opened.sender,
            type: EnvelopeType.retentionActivateAck,
            payload: {'rid': requestId},
          );
          _changes.add(senderId);
        }
      case EnvelopeType.retentionActivateAck:
        if (state.outgoingRequestId == requestId &&
            state.outgoingActivateSent) {
          await _settings.saveDisappearingState(
            senderId,
            state.copyWith(clearOutgoing: true),
          );
          _changes.add(senderId);
        }
      default:
        return;
    }
  }

  Future<void> respondToRequest({
    required IdentityRecord peer,
    required String requestId,
    required bool accept,
  }) async {
    final state = await stateFor(peer.identityId);
    if (state.incomingRequestId != requestId || state.incomingEnabled == null) {
      return;
    }
    if (accept) {
      await _settings.saveDisappearingState(
        peer.identityId,
        state.copyWith(incomingAccepted: true),
      );
    } else {
      await _enqueue(
        peer: peer,
        type: EnvelopeType.retentionResponse,
        payload: {'rid': requestId, 'accepted': false},
      );
      await _settings.saveDisappearingState(
        peer.identityId,
        state.copyWith(
          clearIncoming: true,
          lastRejectedRequestId: requestId,
        ),
      );
    }
    if (accept) {
      await _enqueue(
        peer: peer,
        type: EnvelopeType.retentionResponse,
        payload: {'rid': requestId, 'accepted': true},
      );
    }
    _changes.add(peer.identityId);
  }

  Future<void> _sendCommitAck(IdentityRecord peer, String requestId) =>
      _enqueue(
        peer: peer,
        type: EnvelopeType.retentionCommitAck,
        payload: {'rid': requestId},
      );

  Future<void> _enqueue({
    required IdentityRecord peer,
    required EnvelopeType type,
    required Map<String, Object?> payload,
  }) async {
    if (!await _friends.canExchangeMessages(peer.identityId)) {
      throw const StateTransitionException(
        'Message settings can only be changed with an active friend',
      );
    }
    final known = await _identities.find(peer.identityId);
    if (known == null) {
      throw const ValidationException('This friend identity is not known');
    }
    final now = _clock.now().millisecondsSinceEpoch;
    await _outbox.enqueue(
      sender: _identityHolder.requireIdentity,
      recipient: known.record,
      type: type,
      payload: payload,
      bundleId: Ids.newMessageId(),
      expiresAtMs: now + _config.protocolMessageRetention.inMilliseconds,
    );
  }

  Future<void> dispose() => _changes.close();
}
