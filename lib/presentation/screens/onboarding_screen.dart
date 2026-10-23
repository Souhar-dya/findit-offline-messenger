import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/identity_controller.dart';
import '../widgets/common.dart';
import '../widgets/identity_qr.dart';

/// First-run flow: choose a display name and create the local identity.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final controller = context.read<IdentityController>();
    final ok = await controller.create(_name.text);
    if (!ok && mounted) {
      // Error is surfaced through the controller; nothing else to do.
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<IdentityController>();
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Icon(
                Icons.travel_explore,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Welcome to Paxby',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'Offline-first messaging. No account, no server, no internet '
                'required. Your identity is a key pair created on this device; '
                'only its public half is ever shared.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              if (controller.error != null)
                ErrorBanner(
                  message: controller.error!,
                  onDismiss: controller.clearMessages,
                ),
              TextField(
                controller: _name,
                textInputAction: TextInputAction.done,
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: 'Display name',
                  helperText: 'A display name is a label, not an identity.',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _create(),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: controller.busy ? null : _create,
                icon: controller.busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.key),
                label: const Text('Create identity'),
              ),
              const SizedBox(height: 24),
              const Text(
                'Private keys are stored in the platform secure storage '
                '(Keystore / Keychain) and are never exported.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Second onboarding step: show the public identity QR so a peer can add you.
class OnboardingIdentityScreen extends StatelessWidget {
  const OnboardingIdentityScreen({super.key, required this.onContinue});

  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<IdentityController>();
    final qrData = controller.qrData;
    return Scaffold(
      appBar: AppBar(title: const Text('Your identity')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (qrData != null)
                IdentityQrView(
                  qrData: qrData,
                  identityId: controller.identityId,
                  displayName: controller.displayName,
                ),
              const SizedBox(height: 24),
              const Text(
                'Share this code with someone nearby. Adding a contact still '
                'requires mutual approval in the Friends tab.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: onContinue,
                child: const Text('Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
