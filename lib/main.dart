import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'ui/theme.dart';

void main() {
  runApp(const TaxiffApp());
}

class TaxiffApp extends StatelessWidget {
  const TaxiffApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Taxiff',
      debugShowCheckedModeBanner: false,
      // Claro u oscuro según el teléfono, como las apps de Samsung.
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
