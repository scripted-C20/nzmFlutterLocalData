import "package:flutter/material.dart";

class NzmTheme {
  static const Color bgDeep = Color(0xFF050B14);
  static const Color bgMid = Color(0xFF0A1627);
  static const Color bgSurface = Color(0xFF0E1A2C);
  static const Color card = Color(0xCC0B1626);
  static const Color line = Color(0x3393ADD1);
  static const Color lineStrong = Color(0x6BFFD15C);
  static const Color text = Color(0xFFEAF3FF);
  static const Color muted = Color(0xFF94ABC8);
  static const Color green = Color(0xFF45DD98);
  static const Color red = Color(0xFFFF6666);
  static const Color accent = Color(0xFFFFD15C);

  static ThemeData build() {
    const ColorScheme scheme = ColorScheme.dark(
      primary: Color(0xFF1A5DB7),
      onPrimary: Colors.white,
      secondary: accent,
      onSecondary: Color(0xFF111111),
      surface: bgSurface,
      onSurface: text,
      error: red,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.transparent,
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: text, fontSize: 14),
        bodySmall: TextStyle(color: muted, fontSize: 12),
        titleMedium:
            TextStyle(color: text, fontSize: 18, fontWeight: FontWeight.w700),
        titleSmall:
            TextStyle(color: text, fontSize: 14, fontWeight: FontWeight.w600),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0D1727),
        foregroundColor: text,
        elevation: 0,
      ),
      cardTheme: const CardThemeData(
        color: card,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          side: BorderSide(color: line),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        backgroundColor: const Color(0xFF0B1626),
        indicatorColor: accent.withValues(alpha: 0.22),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>(
            (Set<WidgetState> states) {
          final bool selected = states.contains(WidgetState.selected);
          return TextStyle(
            color: selected ? const Color(0xFFFFDF8D) : muted,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          );
        }),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xEE07101E),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: lineStrong),
        ),
        labelStyle: TextStyle(color: muted),
      ),
      chipTheme: const ChipThemeData(
        shape: StadiumBorder(side: BorderSide(color: line)),
        backgroundColor: Color(0xBB122339),
        selectedColor: Color(0xBB2A2114),
        labelStyle: TextStyle(color: text),
      ),
    );
  }
}
