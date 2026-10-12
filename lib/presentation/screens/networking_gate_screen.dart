import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/settings_controller.dart';

/// The only screen shown while the single master networking switch is off.
///
/// While it is off the app is radio silent: no discovery, no sending and no
/// receiving. Nothing else (the tabs, chats, friends or nearby) is reachable
/// until the switch is turned back on.
class NetworkingGateScreen extends StatelessWidget {
  const NetworkingGateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.wifi_off_rounded,
                    size: 56,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'FindIt is radio silent',
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'This is the only switch. While it is off, nothing is '
                    'discovered, sent or received. Turn it on to start FindIt: '
                    'discover nearby peers and send and receive your own '
                    'messages. Your device may then also carry encrypted '
                    'messages for other people (you can never read them).',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  Card(
                    margin: EdgeInsets.zero,
                    child: SwitchListTile(
                      key: const Key('networking-switch'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      value: settings.networkingEnabled,
                      onChanged: settings.busy
                          ? null
                          : (value) => context
                                .read<SettingsController>()
                                .setNetworkingEnabled(value),
                      title: Text(
                        settings.networkingEnabled
                            ? 'FindIt is on'
                            : 'FindIt is off',
                        style: theme.textTheme.titleMedium,
                      ),
                      subtitle: const Text('Use the radio'),
                    ),
                  ),
                  if (settings.status != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      settings.status!,
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
