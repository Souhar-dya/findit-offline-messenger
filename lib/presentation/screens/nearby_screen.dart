import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/nearby_controller.dart';
import '../widgets/common.dart';

/// The Nearby tab: honest transport status, discovery and the demo peer.
class NearbyScreen extends StatelessWidget {
  const NearbyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<NearbyController>();
    final capabilities = controller.capabilities;
    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (controller.error != null) ErrorBanner(message: controller.error!),
          if (!capabilities.isSimulated)
            const InfoBanner(
              message:
                  'Real device-to-device Wi-Fi is not implemented in this '
                  'build. The Nearby feature below is unavailable; see '
                  'Profile → Transport for details.',
            ),
          SectionCard(
            title: controller.transportName,
            subtitle: capabilities.isSimulated
                ? 'Simulated · no radio is used'
                : 'Unavailable on this platform',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(capabilities.description),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _CapabilityChip(
                      label: 'Discover',
                      enabled: capabilities.canDiscover,
                    ),
                    _CapabilityChip(
                      label: 'Connect',
                      enabled: capabilities.canConnect,
                    ),
                    _CapabilityChip(
                      label: 'Resume',
                      enabled: capabilities.supportsResumableTransfer,
                    ),
                    _CapabilityChip(
                      label: 'Background',
                      enabled: capabilities.supportsBackground,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: controller.busy || !capabilities.canConnect
                          ? null
                          : (controller.isRunning
                                ? controller.stopTransport
                                : controller.startTransport),
                      icon: Icon(
                        controller.isRunning ? Icons.stop : Icons.play_arrow,
                      ),
                      label: Text(controller.isRunning ? 'Stop' : 'Start'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (capabilities.isSimulated)
            SectionCard(
              title: 'Demo peer',
              subtitle: 'Runs a second FindIt instance on this device',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Useful for trying the protocol end to end. It is not a '
                    'real remote device and does not use any radio.',
                  ),
                  const SizedBox(height: 12),
                  if (controller.demoError != null)
                    ErrorBanner(message: controller.demoError!),
                  FilledButton.tonalIcon(
                    onPressed: controller.demoStarting
                        ? null
                        : (controller.demoRunning
                              ? controller.stopDemoPeer
                              : controller.startDemoPeer),
                    icon: controller.demoStarting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            controller.demoRunning
                                ? Icons.person_remove
                                : Icons.person_add,
                          ),
                    label: Text(
                      controller.demoRunning
                          ? 'Stop demo peer'
                          : 'Start demo peer',
                    ),
                  ),
                ],
              ),
            ),
          SectionCard(
            title: 'Connected peers',
            child: controller.sessions.isEmpty
                ? const Text('No active sessions.')
                : Column(
                    children: [
                      for (final session in controller.sessions)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.link),
                          title: Text(
                            session.displayName ?? session.identityId ?? 'Peer',
                          ),
                          subtitle: Text(
                            session.handshaken
                                ? 'Handshake complete'
                                : 'Connecting…',
                          ),
                        ),
                    ],
                  ),
          ),
          SectionCard(
            title: 'Discovered peers',
            child: controller.knownPeers.isEmpty
                ? const Text('No peers discovered yet.')
                : Column(
                    children: [
                      for (final peer in controller.knownPeers)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.wifi_tethering),
                          title: Text(peer.displayNameHint ?? 'Unnamed peer'),
                          subtitle: Text('Handle ${_short(peer.peerId)}'),
                          trailing: TextButton(
                            onPressed: () => controller.connect(peer.peerId),
                            child: const Text('Connect'),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  String _short(String value) =>
      value.length <= 8 ? value : value.substring(0, 8);
}

class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.label, required this.enabled});

  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(
        enabled ? Icons.check_circle : Icons.cancel_outlined,
        size: 18,
        color: enabled ? Colors.green : Theme.of(context).colorScheme.outline,
      ),
      label: Text(label),
    );
  }
}
