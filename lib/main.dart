// main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/walkie_talkie_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Enforce portrait mode for tactical walkie-talkie ergonomics
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Set system UI navigation bar style
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUIOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF121417),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const OfflineWalkieTalkieApp());
}

class OfflineWalkieTalkieApp extends StatelessWidget {
  const OfflineWalkieTalkieApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline Walkie Talkie',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121417),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF22C55E),
          surface: Color(0xFF1E2228),
          onSurface: Colors.white,
        ),
        fontFamily: 'Inter',
      ),
      home: const WalkieTalkieScreen(),
    );
  }
}
