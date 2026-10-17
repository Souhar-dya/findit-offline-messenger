import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/nearby_controller.dart';
import '../widgets/common.dart';

/// The Nearby tab: who is around and who is connected.
///
/// Transport internals (capability reports, "native"/"simulated" naming and
/// rotating peer handles) are deliberately kept off this screen: they are
/// diagnostics, not something a regular user needs. The Profile tab keeps the
/// honest details.
class NearbyScreen extends StatelessWidget {
  const NearbyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<NearbyController>();
    final capabilities = controller.capabilities;
    final simulated = capabilities.isSimulated;
    final available = simulated || capabilities.canDiscover;

    return RefreshIndicator(
      onRefresh: controller.refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (controller.error != null) ErrorBanner(message: controller.error!),
          if (!available)
            const InfoBanner(
              message:
                  'This device cannot look for people nearby. Your chats and '
                  'messages stay saved on this device.',
            ),
          _StatusCard(controller: controller, simulated: simulated),
          if (simulated) _DemoPeerCard(controller: controller),
          SectionCard(
            title: 'Connected',
            child: controller.sessions.isEmpty
                ? const Text('No connected devices yet.')
                : Column(
                    children: [
                      for (final session in controller.sessions)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.link),
                          title: Text(
                            session.displayName ??
                                session.identityId ??
                                'Connected device',
                          ),
                          subtitle: const Text('Connected'),
                        ),
                    ],
                  ),
          ),
          SectionCard(
            title: 'Devices nearby',
            child: controller.knownPeers.isEmpty
                ? Text(
                    controller.isRunning
                        ? 'Searching for devices around you…'
                        : 'Networking is off, so nothing is being looked for. '
                              'Turn it on in Profile.',
                  )
                : Column(
                    children: [
                      for (final peer in controller.knownPeers)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.devices_other),
                          title: Text(
                            peer.displayNameHint ?? 'Unnamed device',
                          ),
                          subtitle: const Text('In range'),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Read-only status: the master switch lives on the Profile tab.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller, required this.simulated});

  final NearbyController controller;
  final bool simulated;

  @override
  Widget build(BuildContext context) {
    final running = controller.isRunning;
    return SectionCard(
      title: running ? 'Looking for people nearby' : 'Nearby',
      subtitle: simulated ? 'Demo mode · no radio is used' : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            running
                ? 'Keep Wi-Fi on and stay nearby. Your devices connect to '
                      'each other by themselves.'
                : 'FindIt is not looking right now. Switch it on in Profile → '
                      'FindIt network to discover devices around you.',
          ),
        ],
      ),
    );
  }
}

/// The in-process demo peer. Only ever shown for the simulated transport.
class _DemoPeerCard extends StatelessWidget {
  const _DemoPeerCard({required this.controller});

  final NearbyController controller;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Demo peer',
      subtitle: 'A second FindIt on this device · no radio is used',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Useful for trying messaging end to end. It is not a real remote '
            'device.',
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
              controller.demoRunning ? 'Stop demo peer' : 'Start demo peer',
            ),
          ),
        ],
      ),
    );
  }
}
