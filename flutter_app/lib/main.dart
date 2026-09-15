import 'package:flutter/material.dart';
import 'screens/anti_spy_home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AntiSpyApp());
}

class AntiSpyApp extends StatelessWidget {
  const AntiSpyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hệ Thống Phát Hiện Chụp Lén - Linux Desktop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF06B6D4),
          secondary: Color(0xFF38BDF8),
          surface: Color(0xFF111827),
          error: Color(0xFFEF4444),
        ),
        fontFamily: 'Roboto',
      ),
      home: const AntiSpyHomeScreen(),
    );
  }
}
