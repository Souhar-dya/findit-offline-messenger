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

class _RootGateState extends State<RootGate> {
  bool _entered = false;

  @override
  void initState() {
    super.initState();
    _entered = context.read<IdentityController>().hasIdentity;
  }

  @override
  Widget build(BuildContext context) {
    // Consent comes first: no networking and no data transfer until the user
    // has explicitly agreed to the terms.
    final services = context.watch<AppServices>();
    if (!services.consentAccepted) {
      return const ConsentScreen();
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
