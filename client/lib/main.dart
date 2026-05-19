import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/background_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackgroundService.initialize();
  runApp(const ExtFrtcApp());
}

class ExtFrtcApp extends StatelessWidget {
  const ExtFrtcApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ExtFRTC',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
        fontFamily: 'GeneralFont',
      ),
      home: const HomeScreen(),
    );
  }
}
