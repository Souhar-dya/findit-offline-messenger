import 'chat_message.dart';

/// Aggregated view of a conversation for the Chats screen.
class ConversationSummary {
  const ConversationSummary({
    required this.peerId,
    required this.displayName,
    required this.lastMessageAtMs,
    required this.lastMessagePreview,
    required this.lastStatus,
    required this.isFriend,
    this.unreadCount = 0,
  });

  final String peerId;
  final String displayName;
  final int lastMessageAtMs;
  final String lastMessagePreview;
  final MessageStatus lastStatus;
  final bool isFriend;
  final int unreadCount;

  String previewFor(ChatMessage message) {
    if (message.payloadType == MessagePayloadType.png) {
      return 'PNG image';
    }
    final text = message.text ?? '';
    return text.length <= 80 ? text : '${text.substring(0, 80)}…';
  }
}
