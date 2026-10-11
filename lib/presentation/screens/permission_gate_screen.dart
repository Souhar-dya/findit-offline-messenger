import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/di/app_services.dart';

/// Shown before any networking when the OS permissions the native transport
/// needs are not granted.
///
/// The app cannot discover or message anyone over Wi-Fi Direct without these,
/// so it does not proceed until the user grants them. The request is triggered
/// automatically when this screen appears, and again on "Grant permission".
class PermissionGateScreen extends StatefulWidget {
  const PermissionGateScreen({super.key});

  @override
  State<PermissionGateScreen> createState() => _PermissionGateScreenState();
}

class _PermissionGateScreenState extends State<PermissionGateScreen> {
  bool _busy = false;
  bool _denied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _request());
  }

  Future<void> _request() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _denied = false;
    });
    try {
      final services = context.read<AppServices>();
      final granted = await services.ensurePermissions();
      if (granted) {
        await services.onPermissionsGranted();
      } else if (mounted) {
        setState(() => _denied = true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSettings() async {
    await context.read<AppServices>().openAppSettings();
  }

  @override
  Widget build(BuildContext context) {
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
                    Icons.wifi_tethering,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Allow nearby devices',
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'FindIt needs the Nearby devices permission to find other '
                    'phones over Wi-Fi Direct. It is never used for location '
                    'tracking. The app cannot discover or message anyone until '
                    'you allow it.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  if (_denied) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Permission was denied. Tap Grant to try again, or open '
                      'Settings and enable Nearby devices / Location for FindIt.',
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const Key('permission-grant'),
                      onPressed: _busy ? null : _request,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check),
                      label: const Text('Grant permission'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _busy ? null : _openSettings,
                    icon: const Icon(Icons.settings),
                    label: const Text('Open app settings'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
