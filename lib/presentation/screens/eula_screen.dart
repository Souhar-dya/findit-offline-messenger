import 'package:flutter/material.dart';

import '../../core/legal/eula.dart';

/// Full-screen reader for the End User License Agreement.
///
/// Opened from the consent gate so the licence can be read in full, offline,
/// before it is accepted.
class EulaScreen extends StatelessWidget {
  const EulaScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('End User License Agreement')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(EulaDocument.subtitle, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Text(EulaDocument.intro),
            for (final section in EulaDocument.sections) ...[
              const SizedBox(height: 16),
              Text(section.heading, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(section.body),
            ],
            const SizedBox(height: 24),
            Text(
              'Contact: kundusouhardya@gmail.com',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
