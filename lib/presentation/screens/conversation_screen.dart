import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/di/app_services.dart';
import '../../domain/entities/chat_message.dart';
import '../controllers/conversation_controller.dart';
import '../widgets/common.dart';
import '../widgets/message_bubble.dart';

/// A single conversation: message history, text input and PNG attachments.
class ConversationScreen extends StatelessWidget {
  const ConversationScreen({
    super.key,
    required this.peerId,
    required this.title,
  });

  final String peerId;
  final String title;

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    return ChangeNotifierProvider<ConversationController>(
      create: (_) => ConversationController(services, peerId)..load(),
      child: _ConversationBody(title: title),
    );
  }
}

class _ConversationBody extends StatefulWidget {
  const _ConversationBody({required this.title});

  final String title;

  @override
  State<_ConversationBody> createState() => _ConversationBodyState();
}

class _ConversationBodyState extends State<_ConversationBody> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<ConversationController>().markRead();
    });
  }

  Future<void> _sendText() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final controller = context.read<ConversationController>();
    _input.clear();
    final ok = await controller.sendText(text);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(controller.error ?? 'Could not send message')),
      );
    }
    _scrollToEnd();
  }

  Future<void> _attachPng() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('Choose a PNG file'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    Uint8List? bytes;
    String filename = 'image.png';
    if (source == 'gallery') {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;
      bytes = await picked.readAsBytes();
      filename = picked.name.isEmpty ? filename : picked.name;
    } else {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['png'],
      );
      if (file == null) return;
      bytes = await file.readAsBytes();
      filename = file.name;
    }
    if (!mounted) return;

    final controller = context.read<ConversationController>();
    final ok = await controller.sendPng(bytes, filename);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(controller.error ?? 'Could not send image (PNG only)'),
        ),
      );
    }
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Flattens messages into bubbles with a day divider before each new day.
  List<Object> _items(List<ChatMessage> messages) {
    final items = <Object>[];
    int? previousMs;
    for (final message in messages) {
      final ms = message.localTimestampMs;
      if (previousMs == null || !isSameLocalDay(previousMs, ms)) {
        items.add(formatDayLabel(ms));
      }
      items.add(message);
      previousMs = ms;
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ConversationController>();
    final items = _items(controller.messages);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title),
            Text(
              controller.isFriend ? 'Friend' : 'Not verified as a friend',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (controller.incomingRetentionRequestId != null &&
              controller.incomingRetentionEnabled != null)
            Card(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      controller.incomingRetentionAccepted
                          ? 'You accepted the request. Waiting for the change to finish on both phones.'
                          : '${controller.displayName} requests to '
                                '${controller.incomingRetentionEnabled! ? 'enable' : 'disable'} '
                                'disappearing messages for both of you.',
                    ),
                    if (!controller.incomingRetentionAccepted) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: controller.updatingDisappearingPreference
                                ? null
                                : () => controller.respondToRetentionRequest(
                                    accept: false,
                                  ),
                            child: const Text('Decline'),
                          ),
                          FilledButton(
                            onPressed: controller.updatingDisappearingPreference
                                ? null
                                : () => controller.respondToRetentionRequest(
                                    accept: true,
                                  ),
                            child: const Text('Accept'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          if (controller.outgoingRetentionRequestId != null)
            ListTile(
              dense: true,
              leading: Icon(
                controller.outgoingRetentionCommitting
                    ? Icons.sync
                    : Icons.hourglass_top,
              ),
              title: Text(
                controller.outgoingRetentionCommitting
                    ? 'Applying shared message setting…'
                    : 'Waiting for ${controller.displayName} to approve this change',
              ),
            ),
          SwitchListTile(
            title: const Text('Disappearing messages'),
            subtitle: Text(
              controller.outgoingRetentionRequestId != null
                  ? 'The current shared setting remains in effect until approved.'
                  : controller.disappearingMessagesEnabled
                  ? 'Messages are deleted from both phones after 24 hours.'
                  : 'Messages are kept on both phones.',
            ),
            value: controller.disappearingMessagesEnabled,
            onChanged: controller.updatingDisappearingPreference ||
                    controller.incomingRetentionRequestId != null ||
                    controller.outgoingRetentionRequestId != null
                ? null
                : controller.setDisappearingMessagesEnabled,
            secondary: const Icon(Icons.timer_outlined),
          ),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: ErrorBanner(message: controller.error!),
            ),
          Expanded(
            child: controller.loading && controller.messages.isEmpty
                ? const LoadingView(label: 'Loading messages…')
                : controller.messages.isEmpty
                ? EmptyState(
                    icon: Icons.lock_outline,
                    title: 'No messages yet',
                    message: controller.disappearingMessagesEnabled
                        ? 'Messages are end-to-end encrypted and deleted after 24 hours.'
                        : 'Messages are end-to-end encrypted and kept on both phones.',
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      if (item is String) return _DayDivider(label: item);
                      return MessageBubble(message: item as ChatMessage);
                    },
                  ),
          ),
          _Composer(
            controller: _input,
            busy: controller.sending || controller.retentionChangeApplying,
            onSend: _sendText,
            onAttach: _attachPng,
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.busy,
    required this.onSend,
    required this.onAttach,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: 'Attach a PNG',
              onPressed: busy ? null : onAttach,
              icon: const Icon(Icons.add_photo_alternate_outlined),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: 'Message',
                  border: InputBorder.none,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Send',
              onPressed: busy ? null : onSend,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

/// A centred date divider shown between messages from different days.
class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.outline),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}
