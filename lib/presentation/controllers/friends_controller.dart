import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/di/app_services.dart';
import '../../core/errors/app_exception.dart';
import '../../crypto/identity_record.dart';
import '../../domain/entities/friend.dart';
import '../../domain/entities/friend_request.dart';
import '../../domain/entities/known_identity.dart';

/// Backs the Friends screen: contacts, pending requests, adds and blocks.
class FriendsController extends ChangeNotifier {
  FriendsController(this._services) {
    _requests = _services.core.friendService.incomingRequests.listen(
      (_) => refresh(),
    );
    _changes = _services.core.friendService.friendshipChanges.listen(
      (_) => refresh(),
    );
  }

  final AppServices _services;
  StreamSubscription<Object?>? _requests;
  StreamSubscription<Object?>? _changes;

  List<FriendRecord> _friends = const [];
  List<FriendRequestRecord> _pending = const [];
  List<KnownIdentity> _known = const [];
  bool _loading = false;
  String? _error;
  String? _status;

  List<FriendRecord> get friends => _friends;
  List<FriendRequestRecord> get pendingRequests => _pending;
  List<KnownIdentity> get knownIdentities => _known;
  bool get loading => _loading;
  String? get error => _error;
  String? get status => _status;

  bool get isEmpty => !_loading && _friends.isEmpty && _pending.isEmpty;

  Future<void> refresh() async {
    _loading = true;
    notifyListeners();
    try {
      final all = await _services.core.friends.allFriends();
      _friends = all
          .where((friend) => friend.status != FriendStatus.declined)
          .toList();
      _pending = (await _services.core.friends.allRequests())
          .where(
            (request) =>
                request.state == FriendRequestState.pending &&
                request.direction == FriendRequestDirection.incoming,
          )
          .toList();
      _known = await _services.core.identities.allKnown();
      _error = null;
    } catch (error) {
      _error = 'Could not load contacts: $error';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<bool> sendRequest(IdentityRecord peer) async {
    _error = null;
    notifyListeners();
    try {
      await _services.core.friendService.sendRequest(peer: peer);
      _status = 'Friend request sent to ${peer.displayName}.';
      await refresh();
      return true;
    } on AppException catch (error) {
      _error = error.message;
      notifyListeners();
      return false;
    }
  }

  /// Verifies and stores a scanned identity, then returns it so the caller can
  /// offer to send a request.
  Future<IdentityRecord?> addScanned(String qrData) async {
    _error = null;
    try {
      final record = IdentityRecord.parseQrData(qrData);
      if (!await record.verify()) {
        _error = 'The scanned identity failed verification.';
        notifyListeners();
        return null;
      }
      if (record.identityId ==
          _services.core.identityHolder.identity?.identityId) {
        _error = 'That is your own identity.';
        notifyListeners();
        return null;
      }
      await _services.core.friendService.rememberIdentity(
        record,
        verified: true,
      );
      _status =
          'Added ${record.displayName}. You can now send a friend request.';
      await refresh();
      return record;
    } on AppException catch (error) {
      _error = error.message;
      notifyListeners();
      return null;
    }
  }

  Future<bool> accept(FriendRequestRecord request) async {
    try {
      await _services.core.friendService.acceptRequest(request);
      _status = 'You are now friends.';
      await refresh();
      return true;
    } on AppException catch (error) {
      _error = error.message;
      notifyListeners();
      return false;
    }
  }

  Future<void> decline(FriendRequestRecord request) async {
    try {
      await _services.core.friendService.declineRequest(request);
      await refresh();
    } on AppException catch (error) {
      _error = error.message;
      notifyListeners();
    }
  }

  Future<void> setBlocked(String identityId, bool blocked) async {
    try {
      await _services.core.friendService.block(identityId, blocked: blocked);
      await refresh();
    } on AppException catch (error) {
      _error = error.message;
      notifyListeners();
    }
  }

  void clearMessages() {
    _error = null;
    _status = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _requests?.cancel();
    _changes?.cancel();
    super.dispose();
  }
}
