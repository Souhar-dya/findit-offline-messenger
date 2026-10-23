import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/di/app_services.dart';
import 'presentation/controllers/chats_controller.dart';
import 'presentation/controllers/friends_controller.dart';
import 'presentation/controllers/identity_controller.dart';
import 'presentation/controllers/nearby_controller.dart';
import 'presentation/controllers/settings_controller.dart';
import 'presentation/screens/consent_screen.dart';
import 'presentation/screens/home_shell.dart';
import 'presentation/screens/networking_gate_screen.dart';
import 'presentation/screens/onboarding_screen.dart';
import 'presentation/screens/permission_gate_screen.dart';

/// The root application widget.
class FindItApp extends StatelessWidget {
  const FindItApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppServices>.value(value: services),
        ChangeNotifierProvider<IdentityController>(
          create: (_) => IdentityController(services)..syncFromHolder(),
        ),
        ChangeNotifierProvider<ChatsController>(
          create: (_) => ChatsController(services),
        ),
        ChangeNotifierProvider<FriendsController>(
          create: (_) => FriendsController(services),
        ),
        ChangeNotifierProvider<NearbyController>(
          create: (_) => NearbyController(services),
        ),
        ChangeNotifierProvider<SettingsController>(
          create: (_) => SettingsController(services),
        ),
      ],
      child: MaterialApp(
        title: 'FindIt',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF2E6B5E),
          useMaterial3: true,
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF2E6B5E),
          useMaterial3: true,
          brightness: Brightness.dark,
        ),
        home: const RootGate(),
      ),
    );
  }
}

/// Chooses between consent, the single networking switch, onboarding, the
/// identity QR step and the main shell.
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> with WidgetsBindingObserver {
  bool _entered = false;
  bool _wifiChecked = false;
  bool _wifiEnabled = false;
  bool _hotspotEnabled = false;

  @override
  void initState() {
    super.initState();
    _entered = context.read<IdentityController>().hasIdentity;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshWifi());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshWifi();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refreshWifi() async {
    if (!mounted) return;
    final services = context.read<AppServices>();
    if (!services.requiresPlatformPermissions) {
      if (mounted) {
        setState(() {
          _wifiChecked = true;
          _wifiEnabled = true;
        });
      }
      return;
    }
    final enabled = await services.isWifiEnabled();
    final hotspotEnabled = await services.isHotspotEnabled();
    if (!mounted) return;
    setState(() {
      _wifiChecked = true;
      _wifiEnabled = enabled;
      _hotspotEnabled = hotspotEnabled;
    });
    if (enabled) await services.ensureNetworkingStarted();
  }

  Future<void> _openWifiSettings() async {
    final services = context.read<AppServices>();
    if (_hotspotEnabled) {
      await services.openHotspotSettings();
    } else {
      await services.requestWifiEnable();
    }
    await _refreshWifi();
  }

  @override
  Widget build(BuildContext context) {
    // Consent comes first: no networking and no data transfer until the user
    // has explicitly agreed to the terms.
    final services = context.watch<AppServices>();
    if (!services.consentAccepted) {
      return const ConsentScreen();
    }
    // The native radio needs OS permissions before it can do anything; ask for
    // them right after consent and do not proceed until they are granted.
    if (services.requiresPlatformPermissions && !services.permissionsGranted) {
      return const PermissionGateScreen();
    }
    // Require Wi-Fi with the hotspot off before exposing the app on Android.
    // Recheck after users return from system settings.
    if (services.requiresPlatformPermissions &&
        (!_wifiChecked || !_wifiEnabled || _hotspotEnabled)) {
      return _WifiRequiredScreen(
        checked: _wifiChecked,
        hotspotEnabled: _hotspotEnabled,
        onOpenSettings: _openWifiSettings,
        onCheckAgain: _refreshWifi,
      );
    }
    // The single master switch: while networking is off the app is radio
    // silent and only that switch is shown.
    if (!services.networkingEnabled) {
      return const NetworkingGateScreen();
    }
    final identity = context.watch<IdentityController>();
    if (!identity.hasIdentity) {
      return const OnboardingScreen();
    }
    if (!_entered) {
      return OnboardingIdentityScreen(
        onContinue: () => setState(() => _entered = true),
      );
    }
    return const HomeShell();
  }
}

class _WifiRequiredScreen extends StatelessWidget {
  const _WifiRequiredScreen({
    required this.checked,
    required this.hotspotEnabled,
    required this.onOpenSettings,
    required this.onCheckAgain,
  });

  final bool checked;
  final bool hotspotEnabled;
  final Future<void> Function() onOpenSettings;
  final Future<void> Function() onCheckAgain;

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
                    Icons.wifi_off_rounded,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    hotspotEnabled
                        ? 'Turn off your hotspot to continue'
                        : 'Turn on Wi-Fi to continue',
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    hotspotEnabled
                        ? 'The hotspot is active and prevents FindIt from '
                              'using Wi-Fi Direct. Turn off the hotspot in '
                              'system settings to continue.'
                        : 'FindIt uses Wi-Fi Direct to find and connect to '
                              'nearby phones. Internet access is not required. '
                              'Wi-Fi is off and the hotspot is not active, so '
                              'FindIt cannot start nearby connections. Enable '
                              'Wi-Fi in system settings; FindIt will continue '
                              'once the radio is on.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  if (!checked) ...[
                    const SizedBox(height: 16),
                    const CircularProgressIndicator(),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: checked ? onOpenSettings : null,
                      icon: const Icon(Icons.settings),
                      label: Text(
                        hotspotEnabled
                            ? 'Open hotspot settings'
                            : 'Open Wi-Fi settings',
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: checked ? onCheckAgain : null,
                    child: const Text('Check again'),
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
