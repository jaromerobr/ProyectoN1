import 'package:flutter/material.dart';

/// Paleta inspirada en One UI (Samsung): fondos neutros, tarjetas blancas o
/// gris muy oscuro, esquinas grandes y un color de acento por función.
class AppColors {
  static const accent = Color(0xFFFF9F0A); // taxi
  static const driver = Color(0xFFFF9F0A);
  static const passenger = Color(0xFF30C26B);
  static const info = Color(0xFF3E91FF);
  static const danger = Color(0xFFF2453D);
  static const purple = Color(0xFF9B6BFF);

  /// Color estable por pasajero (1, 2, 3…) para gráficas y líneas de tiempo.
  static const series = [
    Color(0xFF3E91FF),
    Color(0xFF30C26B),
    Color(0xFFFF9F0A),
    Color(0xFF9B6BFF),
    Color(0xFFFF5C8A),
    Color(0xFF14B8C4),
  ];
  static Color forIndex(int i) => series[i % series.length];
}

/// Colores de superficie que cambian con el tema.
class Surfaces extends ThemeExtension<Surfaces> {
  final Color background, card, cardHigh, divider, textSecondary;

  const Surfaces({
    required this.background,
    required this.card,
    required this.cardHigh,
    required this.divider,
    required this.textSecondary,
  });

  static const light = Surfaces(
    background: Color(0xFFF4F4F6),
    card: Colors.white,
    cardHigh: Color(0xFFEDEDF0),
    divider: Color(0xFFE6E6EA),
    textSecondary: Color(0xFF7C7C84),
  );

  static const dark = Surfaces(
    background: Color(0xFF000000),
    card: Color(0xFF17171A),
    cardHigh: Color(0xFF242428),
    divider: Color(0xFF2C2C30),
    textSecondary: Color(0xFF9A9AA2),
  );

  static Surfaces of(BuildContext context) =>
      Theme.of(context).extension<Surfaces>()!;

  @override
  Surfaces copyWith() => this;

  @override
  Surfaces lerp(Surfaces? other, double t) => t < 0.5 ? this : other ?? this;
}

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final s = dark ? Surfaces.dark : Surfaces.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: b,
    primary: AppColors.accent,
    onPrimary: Colors.black,
    surface: s.background,
  ).copyWith(
    surfaceContainerLowest: s.background,
    surfaceContainerLow: s.card,
    surfaceContainer: s.card,
    surfaceContainerHigh: s.cardHigh,
    surfaceContainerHighest: s.cardHigh,
    outlineVariant: s.divider,
    onSurfaceVariant: s.textSecondary,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    scaffoldBackgroundColor: s.background,
    extensions: [s],
  );
  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: s.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge
          ?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface),
    ),
    dividerTheme: DividerThemeData(color: s.divider, thickness: 1, space: 1),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((st) =>
          st.contains(WidgetState.selected) ? Colors.white : null),
      trackColor: WidgetStateProperty.resolveWith((st) =>
          st.contains(WidgetState.selected) ? AppColors.accent : null),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 6,
      activeTrackColor: AppColors.accent,
      thumbColor: Colors.white,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 18),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: s.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: s.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: s.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: AppColors.accent.withValues(alpha: 0.18),
        selectedForegroundColor: dark ? Colors.white : Colors.black,
        side: BorderSide(color: s.divider),
      ),
    ),
  );
}
