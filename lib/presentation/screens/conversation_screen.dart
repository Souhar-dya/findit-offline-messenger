import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/di/app_services.dart';
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

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ConversationController>();
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
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: ErrorBanner(message: controller.error!),
            ),
          Expanded(
            child: controller.loading && controller.messages.isEmpty
                ? const LoadingView(label: 'Loading messages…')
                : controller.messages.isEmpty
                ? const EmptyState(
                    icon: Icons.lock_outline,
                    title: 'No messages yet',
                    message:
                        'Messages are end-to-end encrypted and expire 24 '
                        'hours after they are created.',
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: controller.messages.length,
                    itemBuilder: (context, index) =>
                        MessageBubble(message: controller.messages[index]),
                  ),
          ),
          _Composer(
            controller: _input,
            busy: controller.sending,
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
