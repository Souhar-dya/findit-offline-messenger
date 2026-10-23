import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/chats_controller.dart';
import '../widgets/common.dart';
import '../../domain/entities/conversation_summary.dart';
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
      child: ListView(
        children: [
          if (controller.friends.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Friends', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            SizedBox(
              height: 92,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: controller.friends.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final friend = controller.friends[index];
                  return SizedBox(
                    width: 72,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _openConversation(
                        context,
                        peerId: friend.peerId,
                        name: friend.displayName,
                      ),
                      child: Column(
                        children: [
                          CircleAvatar(child: Text(_initial(friend.displayName))),
                          const SizedBox(height: 4),
                          Text(
                            friend.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 16),
          ],
          if (controller.conversations.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 28, 16, 16),
              child: Text('Choose a friend above to start a conversation.'),
            )
          else
            for (final conversation in controller.conversations)
              _conversationTile(context, conversation),
        ],
      ),
    );
  }

  Widget _conversationTile(
    BuildContext context,
    ConversationSummary conversation,
  ) => Column(
    children: [
      ListTile(
        leading: CircleAvatar(child: Text(_initial(conversation.displayName))),
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
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
        onTap: () => _openConversation(
          context,
          peerId: conversation.peerId,
          name: conversation.displayName,
        ),
      ),
      const Divider(height: 1),
    ],
  );

  void _openConversation(
    BuildContext context, {
    required String peerId,
    required String name,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConversationScreen(peerId: peerId, title: name),
      ),
    );
  }

  String _initial(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed.characters.first.toUpperCase();
  }
}
