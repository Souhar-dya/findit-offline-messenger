import 'dart:io';

import 'package:findit/app.dart';
import 'package:findit/core/config/app_config.dart';
import 'package:findit/core/di/app_services.dart';
import 'package:findit/core/di/core_services.dart';
import 'package:findit/core/legal/terms.dart';
import 'package:findit/crypto/secret_store.dart';
import 'package:findit/presentation/widgets/common.dart';
import 'package:findit/transport/simulated_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/db.dart';

void main() {
  group('formatBytes', () {
    test('formats bytes, kilobytes and megabytes', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
    });
  });

  /// Builds a real [AppServices] over a temporary SQLite database, with all IO
  /// done outside the widget-test fake-async zone.
  Future<(AppServices, Directory)> buildServices(WidgetTester tester) async {
    final directory = Directory.systemTemp.createTempSync('findit-widget-');
    late AppServices services;
    await tester.runAsync(() async {
      final network = SimulatedNetwork();
      services = AppServices(
        core: await CoreServices.create(
          databaseFactory: testDatabaseFactory,
          databasePath: p.join(directory.path, 'widget.db'),
          secretStore: InMemorySecretStore(),
          transport: SimulatedTransport(network: network),
          config: AppConfig.test,
        ),
        simulatedNetwork: network,
      );
    });
    return (services, directory);
  }

  /// Disposes real IO (closing the database) outside the fake-async zone.
  Future<void> disposeServices(
    WidgetTester tester,
    AppServices services,
    Directory directory,
  ) async {
    await tester.runAsync(services.core.dispose);
    try {
      directory.deleteSync(recursive: true);
    } catch (_) {
      // Temporary directories are reaped by the OS.
    }
  }

  testWidgets('gates the app behind consent, then behind the single switch', (
    WidgetTester tester,
  ) async {
    final (services, directory) = await buildServices(tester);
    try {
      await tester.pumpWidget(FindItApp(services: services));
      await tester.pump();

      // Before consent: the terms are shown and no switch/data is visible.
      expect(find.text(TermsDocument.title), findsOneWidget);
      expect(find.text('FindIt is radio silent'), findsNothing);

      // The action is disabled until the box is ticked.
      final agreeButton = find.byKey(const Key('consent-agree'));
      expect(tester.widget<FilledButton>(agreeButton).onPressed, isNull);

      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      expect(tester.widget<FilledButton>(agreeButton).onPressed, isNotNull);

      // Agreeing moves to the single switch, and nothing else is shown.
      await tester.runAsync(services.acceptConsent);
      await tester.pump();
      expect(find.text(TermsDocument.title), findsNothing);
      expect(find.text('FindIt is radio silent'), findsOneWidget);
      expect(find.text('Welcome to FindIt'), findsNothing);

      final switchTile = find.byKey(const Key('networking-switch'));
      expect(tester.widget<SwitchListTile>(switchTile).value, isFalse);

      // Turning the switch on starts the app: onboarding appears.
      await tester.tap(switchTile);
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      expect(find.text('FindIt is radio silent'), findsNothing);
      expect(find.text('Welcome to FindIt'), findsOneWidget);
    } finally {
      await disposeServices(tester, services, directory);
    }
  });

  testWidgets('onboarding renders and validates an empty display name', (
    WidgetTester tester,
  ) async {
    final (services, directory) = await buildServices(tester);
    try {
      await tester.runAsync(() async {
        await services.acceptConsent();
        await services.setNetworkingEnabled(true);
      });

      await tester.pumpWidget(FindItApp(services: services));
      await tester.pump();

      // The first-run flow is shown when no identity exists yet.
      expect(find.text('Welcome to FindIt'), findsOneWidget);
      expect(find.text('Create identity'), findsOneWidget);
      expect(find.text('Your identity'), findsNothing);

      // An empty name is rejected locally, without any networking.
      await tester.tap(find.text('Create identity'));
      await tester.pump();

      expect(find.text('Please enter a display name.'), findsOneWidget);
      expect(find.text('Your identity'), findsNothing);
    } finally {
      await disposeServices(tester, services, directory);
    }
  });
}
