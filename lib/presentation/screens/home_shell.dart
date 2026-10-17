import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/di/app_services.dart';
import '../controllers/chats_controller.dart';
import '../controllers/friends_controller.dart';
import '../controllers/nearby_controller.dart';
import '../controllers/settings_controller.dart';
import 'chats_screen.dart';
import 'friends_screen.dart';
import 'nearby_screen.dart';
import 'profile_screen.dart';

/// The authenticated shell with the four primary tabs.
///
/// It also watches the Wi-Fi radio: while networking is on but Wi-Fi is off the
/// app cannot reach anyone, so a full-screen prompt asks the user to turn Wi-Fi
/// back on instead of silently doing nothing.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  Timer? _wifiTimer;
  bool _wifiOff = false;
  bool _wifiPromptDismissed = false;
  bool _hotspotOn = false;
  bool _hotspotPromptDismissed = false;

  static const List<String> _titles = ['Chats', 'Friends', 'Nearby', 'Profile'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshCurrent();
      _checkWifi();
    });
    _wifiTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _checkWifi(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkWifi();
  }

  @override
  void dispose() {
    _wifiTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _refreshCurrent() {
    switch (_index) {
      case 0:
        context.read<ChatsController>().refresh();
      case 1:
        context.read<FriendsController>().refresh();
      case 2:
        context.read<NearbyController>().refresh();
      case 3:
        context.read<SettingsController>().refresh();
    }
  }

  /// Re-reads the Wi-Fi radio and hotspot state. Both only matter for the
  /// native transport and only while networking is switched on.
  Future<void> _checkWifi() async {
    if (!mounted) return;
    final services = context.read<AppServices>();
    if (!services.requiresPlatformPermissions || !services.networkingEnabled) {
      if (_wifiOff || _hotspotOn) {
        setState(() {
          _wifiOff = false;
          _hotspotOn = false;
        });
      }
      return;
    }
    final enabled = await services.isWifiEnabled();
    if (!mounted) return;
    if (!enabled) {
      if (!_wifiOff) setState(() => _wifiOff = true);
      return;
    }
    if (_wifiOff || _wifiPromptDismissed) {
      setState(() {
        _wifiOff = false;
        _wifiPromptDismissed = false;
      });
    }
    // A running hotspot (SoftAP) usually blocks Wi-Fi Direct, so warn the user
    // rather than silently failing to find anyone.
    final hotspot = await services.isHotspotEnabled();
    if (!mounted) return;
    if (hotspot != _hotspotOn) setState(() => _hotspotOn = hotspot);
    if (!hotspot && _hotspotPromptDismissed) {
      setState(() => _hotspotPromptDismissed = false);
    }
    // A start that raced Wi-Fi off (the app was opened with the radio off) has
    // to be retried now that the radio is back, or nothing is ever discovered.
    await services.ensureNetworkingStarted();
  }

  Future<void> _enableWifi() async {
    final services = context.read<AppServices>();
    await services.requestWifiEnable();
    await _checkWifi();
  }

  Future<void> _openHotspotSettings() async {
    await context.read<AppServices>().openHotspotSettings();
    await _checkWifi();
  }

  void _dismissWifiPrompt() => setState(() => _wifiPromptDismissed = true);

  @override
  Widget build(BuildContext context) {
    final screens = const [
      ChatsScreen(),
      FriendsScreen(),
      NearbyScreen(),
      ProfileScreen(),
    ];
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(title: Text(_titles[_index])),
          body: IndexedStack(index: _index, children: screens),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (index) {
              setState(() => _index = index);
              _refreshCurrent();
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble),
                label: 'Chats',
              ),
              NavigationDestination(
                icon: Icon(Icons.people_outline),
                selectedIcon: Icon(Icons.people),
                label: 'Friends',
              ),
              NavigationDestination(
                icon: Icon(Icons.wifi_tethering),
                label: 'Nearby',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: 'Profile',
              ),
            ],
          ),
        ),
        if (_wifiOff && !_wifiPromptDismissed)
          Positioned.fill(
            child: _WifiPrompt(
              onEnable: _enableWifi,
              onLater: _dismissWifiPrompt,
            ),
          ),
        if (!_wifiOff && _hotspotOn && !_hotspotPromptDismissed)
          Positioned.fill(
            child: _HotspotPrompt(
              onOpenSettings: _openHotspotSettings,
              onLater: () => setState(() => _hotspotPromptDismissed = true),
            ),
          ),
      ],
    );
  }
}

/// A dismissible overlay warning that the phone's hotspot is on, which usually
/// stops Wi-Fi Direct from finding anyone.
class _HotspotPrompt extends StatelessWidget {
  const _HotspotPrompt({required this.onOpenSettings, required this.onLater});

  final Future<void> Function() onOpenSettings;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.black54,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.wifi_tethering_rounded,
                    size: 56,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Turn off your hotspot',
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Your phone is sharing its connection. On most phones that '
                    'stops FindIt from finding people nearby. Turn the hotspot '
                    'off and your devices connect by themselves.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      TextButton(
                        onPressed: onLater,
                        child: const Text('Not now'),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: onOpenSettings,
                        icon: const Icon(Icons.settings),
                        label: const Text('Open settings'),
                      ),
                    ],
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

/// A blocking-but-escapable overlay asking the user to turn Wi-Fi on.
class _WifiPrompt extends StatelessWidget {
  const _WifiPrompt({required this.onEnable, required this.onLater});

  final Future<void> Function() onEnable;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.black54,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(20),
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
                    'Turn Wi-Fi on',
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'FindIt talks to nearby devices directly over Wi-Fi '
                    '(Wi-Fi Direct). With Wi-Fi off it cannot find or message '
                    'anyone. Turn it on and your devices connect by themselves.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      TextButton(
                        onPressed: onLater,
                        child: const Text('Not now'),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: onEnable,
                        icon: const Icon(Icons.wifi),
                        label: const Text('Turn on Wi-Fi'),
                      ),
                    ],
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
