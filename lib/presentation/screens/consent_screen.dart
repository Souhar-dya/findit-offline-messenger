import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/di/app_services.dart';
import '../../core/legal/terms.dart';

/// The consent gate shown before any networking.
///
/// Nothing is exchanged until the user explicitly agrees. Declining simply
/// leaves the app on this screen: there is no way to transfer data without
/// consent.
class ConsentScreen extends StatefulWidget {
  const ConsentScreen({super.key});

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  bool _agreed = false;
  bool _busy = false;

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      await context.read<AppServices>().acceptConsent();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Icon(
                    Icons.privacy_tip_outlined,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    TermsDocument.title,
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Text(TermsDocument.intro),
                  const SizedBox(height: 8),
                  for (final section in TermsDocument.sections) ...[
                    const SizedBox(height: 16),
                    Text(section.heading, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(section.body),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    'Version ${TermsDocument.version}.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _agreed,
                    onChanged: _busy
                        ? null
                        : (value) =>
                              setState(() => _agreed = value ?? false),
                    title: const Text(
                      'I have read and agree to the terms above.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const Key('consent-agree'),
                      onPressed: _agreed && !_busy ? _accept : null,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check),
                      label: const Text('Agree and continue'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Declining leaves the app here. No messages are sent or '
                    'received, and nothing is stored for other people.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
