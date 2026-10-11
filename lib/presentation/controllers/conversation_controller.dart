import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/di/app_services.dart';
import '../../core/errors/app_exception.dart';
import '../../crypto/identity_record.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/entities/friend.dart';

/// Backs a single conversation screen.
class ConversationController extends ChangeNotifier {
  ConversationController(this._services, this.peerId) {
    _incoming = _services.core.messageService.incomingMessages.listen((
      message,
    ) {
      if (message.peerId == peerId) refresh();
    });
  }

  final AppServices _services;
  final String peerId;
  StreamSubscription<Object?>? _incoming;

  List<ChatMessage> _messages = const [];
  FriendRecord? _friend;
  IdentityRecord? _peerRecord;
  bool _loading = false;
  bool _sending = false;
  String? _error;

  List<ChatMessage> get messages => _messages;
  FriendRecord? get friend => _friend;
  bool get loading => _loading;
  bool get sending => _sending;
  String? get error => _error;

  String get displayName =>
      _friend?.displayName ?? _peerRecord?.displayName ?? _shortId(peerId);

  bool get isFriend => _friend?.isAccepted ?? false;

  Future<void> load() async {
    _loading = true;
    notifyListeners();
    try {
      _messages = await _services.core.messages.conversation(peerId);
      _friend = await _services.core.friends.findFriend(peerId);
      _peerRecord = (await _services.core.identities.find(peerId))?.record;
      _error = null;
    } catch (error) {
      _error = 'Could not load this conversation: $error';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() => load();

  Future<void> markRead() async {
    await _services.core.messageService.markRead(peerId);
    await _services.core.messages.markConversationRead(
      peerId,
      _services.core.clock.now().millisecondsSinceEpoch,
    );
  }

  Future<bool> sendText(String text) async {
    final recipient = await _recipient();
    if (recipient == null) return false;
    return _guard(() async {
      await _services.core.messageService.sendText(
        recipient: recipient,
        text: text,
      );
    });
  }

  Future<bool> sendPng(Uint8List bytes, String filename) async {
    final recipient = await _recipient();
    if (recipient == null) return false;
    return _guard(() async {
      await _services.core.messageService.sendPng(
        recipient: recipient,
        bytes: bytes,
        filename: filename,
      );
    });
  }

  Future<bool> _guard(Future<void> Function() action) async {
    _sending = true;
    _error = null;
    notifyListeners();
    try {
      await action();
      await load();
      return true;
    } on AppException catch (error) {
      _error = error.message;
      notifyListeners();
      return false;
    } finally {
      _sending = false;
      notifyListeners();
    }
  }

  Future<IdentityRecord?> _recipient() async {
    final record =
        _peerRecord ?? (await _services.core.identities.find(peerId))?.record;
    if (record == null) {
      _error = 'This contact is not known yet. Scan their QR code first.';
      notifyListeners();
      return null;
    }
    _peerRecord = record;
    return record;
  }

  String _shortId(String id) =>
      id.length <= 12 ? id : '${id.substring(0, 10)}…';

  @override
  void dispose() {
    _incoming?.cancel();
    super.dispose();
  }
}
