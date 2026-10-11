import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/di/app_services.dart';
import '../../domain/entities/conversation_summary.dart';

/// Backs the Chats screen: the list of conversations ordered by recency.
class ChatsController extends ChangeNotifier {
  ChatsController(this._services) {
    _messages = _services.core.messageService.incomingMessages.listen(
      (_) => refresh(),
    );
  }

  final AppServices _services;
  StreamSubscription<Object?>? _messages;

  List<ConversationSummary> _conversations = const [];
  bool _loading = false;
  String? _error;

  List<ConversationSummary> get conversations => _conversations;
  bool get loading => _loading;
  String? get error => _error;
  bool get isEmpty => !_loading && _conversations.isEmpty;

  Future<void> refresh() async {
    _loading = true;
    notifyListeners();
    try {
      _conversations = await _services.core.messages.conversations();
      _error = null;
    } catch (error) {
      _error = 'Could not load conversations: $error';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _messages?.cancel();
    super.dispose();
  }
}
