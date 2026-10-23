import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/identity_controller.dart';
import '../controllers/settings_controller.dart';
import '../widgets/common.dart';
import '../widgets/identity_qr.dart';

/// The Profile tab: identity, transport honesty notes, storage and reset.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final identity = context.watch<IdentityController>();
    final settings = context.watch<SettingsController>();
    final qrData = identity.qrData;
    final connectionNote = settings.isSimulated
        ? 'This build runs a self-contained demo. No Wi-Fi or Bluetooth is '
              'used.'
        : settings.canDiscover
        ? 'Paxby reaches other nearby Paxby devices directly over Wi-Fi. '
              'Both devices need Wi-Fi on and must be within range.'
        : 'This device cannot reach other nearby devices over Wi-Fi yet, so '
              'discovery is unavailable.';

    return RefreshIndicator(
      onRefresh: settings.refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (identity.error != null)
            ErrorBanner(
              message: identity.error!,
              onDismiss: identity.clearMessages,
            ),
          if (identity.status != null)
            InfoBanner(
              message: identity.status!,
              onDismiss: identity.clearMessages,
            ),
          SectionCard(
            title: identity.displayName.isEmpty
                ? 'Your identity'
                : identity.displayName,
            subtitle:
                'Public record only · private keys never leave this device',
            child: qrData == null
                ? const Text('No identity is loaded.')
                : IdentityQrView(
                    qrData: qrData,
                    identityId: identity.identityId,
                    displayName: identity.displayName,
                  ),
          ),
          SectionCard(
            title: 'Display name',
            subtitle:
                'A label, not an identity. Changing it re-signs your '
                'public record.',
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: identity.busy
                    ? null
                    : () => _rename(context, identity),
                icon: const Icon(Icons.edit),
                label: const Text('Change display name'),
              ),
            ),
          ),
          SectionCard(
            title: 'Connection',
            subtitle: settings.isSimulated
                ? 'Demo mode · no radio is used'
                : settings.canDiscover
                ? 'On this device'
                : 'Not available on this device',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(connectionNote),
                const SizedBox(height: 8),
                const Text(
                  'Background delivery is best-effort only. Message delivery '
                  'is never guaranteed; expiry is enforced 24 hours after a '
                  'message is created, and is never extended by relaying.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Paxby networking',
            subtitle: settings.networkingEnabled
                ? 'On · discovering nearby peers and exchanging messages'
                : 'Off · radio silent (nothing discovered, sent or received)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: settings.networkingEnabled,
                  onChanged: settings.busy
                      ? null
                      : (value) => settings.setNetworkingEnabled(value),
                  title: Text(
                    settings.networkingEnabled
                        ? 'Paxby is on'
                        : 'Paxby is radio silent',
                  ),
                ),
                const Text(
                  'This is the single master switch and it is off by default. '
                  'While it is off the radio is silent: nothing is discovered, '
                  'sent or received, and your messages are held on this device. '
                  'Turn it on to discover nearby peers and send/receive your own '
                  'messages; your device may then also carry encrypted messages '
                  'addressed to other people (you can never read them). Turning '
                  'it off again stops everything and deletes any messages for '
                  'other people this device was holding.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Storage',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: settings.quotaFraction),
                const SizedBox(height: 8),
                Text(
                  '${formatBytes(settings.totalBytes)} used of '
                  '${formatBytes(settings.quotaBytes)}',
                ),
                const SizedBox(height: 8),
                const Text(
                  'When storage fills up, Paxby automatically removes the '
                  'oldest messages first.',
                  style: TextStyle(fontSize: 12),
                ),
                if (settings.status != null) ...[
                  const SizedBox(height: 8),
                  Text(settings.status!),
                ],
              ],
            ),
          ),
          SectionCard(
            title: 'Danger zone',
            subtitle:
                'Removes the local identity and all local data. This '
                'cannot be undone and cannot be recovered.',
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.errorContainer,
                  foregroundColor: Theme.of(
                    context,
                  ).colorScheme.onErrorContainer,
                ),
                onPressed: identity.busy
                    ? null
                    : () => _confirmReset(context, identity),
                icon: const Icon(Icons.delete_forever),
                label: const Text('Reset identity and data'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _rename(
    BuildContext context,
    IdentityController identity,
  ) async {
    final field = TextEditingController(text: identity.displayName);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(controller: field, maxLength: 60, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    field.dispose();
    if (value != null) await identity.rename(value);
  }

  Future<void> _confirmReset(
    BuildContext context,
    IdentityController identity,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset everything?'),
        content: const Text(
          'Your identity key pair, contacts, messages and anything held for '
          'others will be permanently deleted from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await identity.reset();
  }
}
