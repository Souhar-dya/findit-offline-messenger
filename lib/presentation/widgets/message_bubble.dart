import 'package:flutter/material.dart';

import '../../domain/entities/chat_message.dart';
import 'common.dart';

/// A single chat bubble with delivery state and remaining lifetime.
class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});

  final ChatMessage message;

  bool get _outgoing => message.direction == MessageDirection.outgoing;

  String get _statusLabel {
    switch (message.status) {
      case MessageStatus.pending:
      case MessageStatus.queued:
        return 'Sending…';
      case MessageStatus.unconfirmed:
        return 'Delivery unconfirmed';
      case MessageStatus.delivered:
        return 'Delivered';
      case MessageStatus.received:
        return 'Received';
      case MessageStatus.expired:
        return 'Expired';
      case MessageStatus.failed:
        return 'Failed';
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final expired = message.isExpiredAt(DateTime.now().millisecondsSinceEpoch);
    final bubbleColor = _outgoing
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final textColor = _outgoing ? scheme.onPrimaryContainer : scheme.onSurface;

    return Align(
      alignment: _outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: _outgoing
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (message.payloadType == MessagePayloadType.png &&
                message.imageBytes != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: PngPreview(bytes: message.imageBytes!),
              )
            else
              SelectableText(
                message.text ?? '',
                style: TextStyle(color: textColor),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  formatTimestamp(message.createdAtMs),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                if (_outgoing)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        message.status == MessageStatus.delivered
                            ? Icons.done_all
                            : Icons.schedule,
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _statusLabel,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                if (!expired && !_outgoing)
                  Text(
                    formatRemaining(message.expiresAtMs),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
