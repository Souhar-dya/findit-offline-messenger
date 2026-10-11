import '../entities/chat_message.dart';
import '../entities/conversation_summary.dart';

/// Persistence for chat messages and conversations.
abstract class MessageRepository {
  /// Atomically inserts a message. Returns `false` when the id already exists
  /// (deduplication via the UNIQUE constraint, not a check-then-insert).
  Future<bool> insertIfAbsent(ChatMessage message);

  Future<ChatMessage?> find(String id);

  Future<bool> exists(String id);

  Future<void> updateStatus(
    String id,
    MessageStatus status, {
    int? deliveredAtMs,
    int? receivedAtMs,
  });

  Future<void> markConversationRead(String peerId, int nowMs);

  /// Messages in one conversation, oldest first.
  Future<List<ChatMessage>> conversation(String peerId, {int limit = 500});

  Future<List<ChatMessage>> recentMessages({int limit = 100});

  /// Outbound messages still awaiting forwarding or confirmation.
  Future<List<ChatMessage>> outboundWithStatus(
    Set<MessageStatus> statuses, {
    int limit = 200,
  });

  Future<List<ConversationSummary>> conversations();

  Future<int> totalPayloadBytes();

  /// Marks messages past their expiry, reclaims their payload bytes and writes
  /// tombstones so stale copies cannot be reintroduced.
  /// Returns the number of messages expired.
  Future<int> expireMessages(int nowMs, {required int tombstoneExpiresAtMs});

  Future<void> delete(String id);
}
