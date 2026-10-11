import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/chats_controller.dart';
import '../widgets/common.dart';
import 'conversation_screen.dart';

/// The Chats tab: conversations ordered by most recent message.
class ChatsScreen extends StatelessWidget {
  const ChatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChatsController>();
    if (controller.loading && controller.conversations.isEmpty) {
      return const LoadingView(label: 'Loading conversations…');
    }
    if (controller.error != null && controller.conversations.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: ErrorBanner(message: controller.error!),
      );
    }
    if (controller.isEmpty) {
      return const EmptyState(
        icon: Icons.forum_outlined,
        title: 'No conversations yet',
        message:
            'Messages you send and receive will appear here. Add a friend from '
            'the Friends tab to get started.',
      );
    }
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView.separated(
        itemCount: controller.conversations.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final conversation = controller.conversations[index];
          return ListTile(
            leading: CircleAvatar(
              child: Text(_initial(conversation.displayName)),
            ),
            title: Row(
              children: [
                Expanded(child: Text(conversation.displayName)),
                if (!conversation.isFriend)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(
                      Icons.help_outline,
                      size: 14,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
              ],
            ),
            subtitle: Text(
              conversation.lastMessagePreview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatTimestamp(conversation.lastMessageAtMs),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                if (conversation.unreadCount > 0)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${conversation.unreadCount}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimary,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ConversationScreen(
                    peerId: conversation.peerId,
                    title: conversation.displayName,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _initial(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed.characters.first.toUpperCase();
  }
}
