import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../domain/entities/friend.dart';
import '../controllers/friends_controller.dart';
import '../widgets/common.dart';
import '../widgets/qr_scanner_page.dart';
import 'conversation_screen.dart';

/// The Friends tab: pending requests, contacts, QR add and blocking.
class FriendsScreen extends StatelessWidget {
  const FriendsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<FriendsController>();
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: controller.refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (controller.error != null)
              ErrorBanner(
                message: controller.error!,
                onDismiss: controller.clearMessages,
              ),
            if (controller.status != null)
              InfoBanner(
                message: controller.status!,
                onDismiss: controller.clearMessages,
              ),
            ..._requests(context, controller),
            _friendsSection(context, controller),
            const SizedBox(height: 80),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addFriendDialog(context, controller),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add friend'),
      ),
    );
  }

  List<Widget> _requests(BuildContext context, FriendsController controller) {
    final widgets = <Widget>[];
    final incoming = controller.pendingRequests;
    final outgoing = controller.outgoingRequests;
    if (incoming.isNotEmpty) {
      widgets.add(
        Text('Requests', style: Theme.of(context).textTheme.titleMedium),
      );
      widgets.add(const SizedBox(height: 8));
      for (final request in incoming) {
        widgets.add(
          Card(
            child: ListTile(
              leading: const Icon(Icons.person_add),
              title: Text(request.peerDisplayName ?? _shortId(request.fromId)),
              subtitle: Text(
                'Requested you · expires '
                '${formatTimestamp(request.expiresAtMs)}',
              ),
              trailing: Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: () => controller.decline(request),
                    child: const Text('Decline'),
                  ),
                  FilledButton(
                    onPressed: () => controller.accept(request),
                    child: const Text('Accept'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      widgets.add(const SizedBox(height: 16));
    }
    if (outgoing.isNotEmpty) {
      widgets.add(
        Text('Sent requests', style: Theme.of(context).textTheme.titleMedium),
      );
      widgets.add(const SizedBox(height: 8));
      for (final request in outgoing) {
        widgets.add(
          Card(
            child: ListTile(
              leading: const Icon(Icons.hourglass_top),
              title: Text(request.peerDisplayName ?? _shortId(request.toId)),
              subtitle: const Text('Waiting for them to accept'),
              trailing: TextButton(
                onPressed: () => controller.cancel(request),
                child: const Text('Cancel'),
              ),
            ),
          ),
        );
      }
      widgets.add(const SizedBox(height: 16));
    }
    return widgets;
  }

  Widget _friendsSection(BuildContext context, FriendsController controller) {
    if (controller.friends.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 48),
        child: EmptyState(
          icon: Icons.people_outline,
          title: 'No contacts yet',
          message:
              'Scan a nearby identity QR code or paste their identity payload. '
              'Friendship always requires approval from both sides.',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Contacts', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final friend in controller.friends)
          _FriendTile(
            friend: friend,
            onChat: () => _openChat(context, friend),
            onToggleBlock: () => controller.setBlocked(
              friend.peerId,
              friend.status != FriendStatus.blocked,
            ),
            onRemove: () => _confirmRemove(context, controller, friend),
            onCancel: friend.status == FriendStatus.pendingOutgoing
                ? () => controller.cancelRequestTo(friend.peerId)
                : null,
            onCopyId: () => _copyId(context, friend.peerId),
          ),
      ],
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    FriendsController controller,
    FriendRecord friend,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove contact?'),
        content: Text(
          '${friend.displayName} will be removed from your contacts. '
          'Your chat history stays on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.removeFriend(friend.peerId);
    }
  }

  void _openChat(BuildContext context, FriendRecord friend) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConversationScreen(
          peerId: friend.peerId,
          title: friend.displayName,
        ),
      ),
    );
  }

  Future<void> _copyId(BuildContext context, String id) async {
    await Clipboard.setData(ClipboardData(text: id));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Identity id copied')));
    }
  }

  Future<void> _addFriendDialog(
    BuildContext context,
    FriendsController controller,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('Scan identity QR'),
              onTap: () => Navigator.pop(context, 'scan'),
            ),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Paste identity payload'),
              onTap: () => Navigator.pop(context, 'paste'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    String? payload;
    if (action == 'scan') {
      payload = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(builder: (_) => const QrScannerPage()),
      );
    } else {
      payload = await _promptForPayload(context);
    }
    if (payload == null || payload.trim().isEmpty) return;

    final record = await controller.addScanned(payload.trim());
    if (record == null || !context.mounted) return;

    final send = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send friend request?'),
        content: Text(
          'Send a mutual friend request to ${record.displayName}? '
          'They must accept before you can chat.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send request'),
          ),
        ],
      ),
    );
    if (send == true) {
      await controller.sendRequest(record);
    }
  }

  Future<String?> _promptForPayload(BuildContext context) async {
    final field = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paste identity payload'),
        content: TextField(
          controller: field,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'findit://… or base64 payload',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    field.dispose();
    return value;
  }

  String _shortId(String id) =>
      id.length <= 12 ? id : '${id.substring(0, 10)}…';
}

class _FriendTile extends StatelessWidget {
  const _FriendTile({
    required this.friend,
    required this.onChat,
    required this.onToggleBlock,
    required this.onRemove,
    required this.onCopyId,
    this.onCancel,
  });

  final FriendRecord friend;
  final VoidCallback onChat;
  final VoidCallback onToggleBlock;
  final VoidCallback onRemove;
  final VoidCallback onCopyId;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final blocked = friend.status == FriendStatus.blocked;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          child: Icon(blocked ? Icons.block : _statusIcon(friend.status)),
        ),
        title: Text(friend.displayName),
        subtitle: Text(_statusLabel(friend)),
        onTap: friend.isAccepted ? onChat : null,
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            switch (value) {
              case 'chat':
                onChat();
              case 'cancel':
                onCancel?.call();
              case 'remove':
                onRemove();
              case 'block':
                onToggleBlock();
              case 'copy':
                onCopyId();
            }
          },
          itemBuilder: (context) => [
            if (friend.isAccepted)
              const PopupMenuItem(value: 'chat', child: Text('Open chat')),
            if (friend.status == FriendStatus.pendingOutgoing)
              const PopupMenuItem(
                value: 'cancel',
                child: Text('Cancel request'),
              ),
            if (friend.isAccepted || blocked)
              const PopupMenuItem(
                value: 'remove',
                child: Text('Remove contact'),
              ),
            PopupMenuItem(
              value: 'block',
              child: Text(blocked ? 'Unblock' : 'Block'),
            ),
            const PopupMenuItem(value: 'copy', child: Text('Copy identity id')),
          ],
        ),
      ),
    );
  }

  IconData _statusIcon(FriendStatus status) {
    switch (status) {
      case FriendStatus.accepted:
        return Icons.verified_user;
      case FriendStatus.pendingOutgoing:
        return Icons.hourglass_top;
      case FriendStatus.pendingIncoming:
        return Icons.person_add;
      case FriendStatus.declined:
        return Icons.do_not_disturb;
      case FriendStatus.blocked:
        return Icons.block;
    }
  }

  String _statusLabel(FriendRecord friend) {
    switch (friend.status) {
      case FriendStatus.accepted:
        return friend.isVerified ? 'Verified friend' : 'Friend';
      case FriendStatus.pendingOutgoing:
        return 'Request sent · awaiting approval';
      case FriendStatus.pendingIncoming:
        return 'Requested you';
      case FriendStatus.declined:
        return 'Declined';
      case FriendStatus.blocked:
        return 'Blocked';
    }
  }
}
