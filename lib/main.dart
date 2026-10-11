import 'package:flutter/material.dart';

import 'app.dart';
import 'core/di/app_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppBootstrap.create();
  runApp(FindItApp(services: services));
}
