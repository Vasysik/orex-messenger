import 'package:flutter/material.dart';

/// Палитра Orex Messenger.
///
/// Тёплая орехово-медная гамма, взятая с логотипа: медный градиент фона,
/// оттенки грецкого ореха, золотистая охра и кремовый. Никакого холодного
/// синего и плоского серого.
class OrexColors {
  OrexColors._();

  // --- Базовые «ореховые» тона ---
  static const Color walnut = Color(0xFF8B5A2B); // грецкий орех
  static const Color walnutDeep = Color(0xFF5E3A1A); // глубокий орех
  static const Color copper = Color(0xFFC8763C); // медь (углы иконки)
  static const Color copperBright = Color(0xFFD98C4A); // светлая медь
  static const Color ochre = Color(0xFFD9A05B); // золотистая охра
  static const Color ochreLight = Color(0xFFE7C18B); // светлая охра
  static const Color cream = Color(0xFFFBF5EC); // кремовый (тело иконки)

  // --- Светлая тема ---
  static const Color lightBg = Color(0xFFF6ECDD);
  static const Color lightSurface = Color(0xFFFBF3E7);
  static const Color lightBubbleIn = Color(0xFFFFFFFF);
  static const Color lightBubbleOut = Color(0xFFE9B97F); // исходящие — медовые
  static const Color lightText = Color(0xFF3A2417);
  static const Color lightTextSoft = Color(0xFF8A6E55);

  // --- Тёмная тема: «чёрный шоколад» с медными отливами ---
  static const Color darkBg = Color(0xFF1C140E); // древесный уголь / шоколад
  static const Color darkBgRaised = Color(0xFF241912);
  static const Color darkSurface = Color(0xFF2A1D14);
  static const Color darkBubbleIn = Color(0xFF33241A);
  static const Color darkBubbleOut = Color(0xFF7A4A24); // исходящие — медь
  static const Color darkText = Color(0xFFF3E6D5);
  static const Color darkTextSoft = Color(0xFFB39A82);

  static const Color unread = Color(0xFFC8763C);
  static const Color online = Color(0xFF8FB36A); // тёплый зелёный, не кислотный

  /// Медный градиент для splash / аватаров / акцентов.
  static const LinearGradient copperGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [copperBright, walnutDeep],
  );

  /// Фоновый «амбиентный» градиент под стеклом (тёмная тема).
  static const RadialGradient ambientDark = RadialGradient(
    center: Alignment(-0.6, -0.8),
    radius: 1.4,
    colors: [Color(0xFF3A2415), darkBg],
  );

  static const RadialGradient ambientLight = RadialGradient(
    center: Alignment(-0.6, -0.8),
    radius: 1.4,
    colors: [Color(0xFFFBEAD2), lightBg],
  );
}

class OrexTheme {
  OrexTheme._();

  static ThemeData get dark => _build(Brightness.dark);
  static ThemeData get light => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    final scheme = ColorScheme(
      brightness: brightness,
      primary: OrexColors.copper,
      onPrimary: OrexColors.cream,
      secondary: OrexColors.ochre,
      onSecondary: OrexColors.walnutDeep,
      surface: isDark ? OrexColors.darkSurface : OrexColors.lightSurface,
      onSurface: isDark ? OrexColors.darkText : OrexColors.lightText,
      error: const Color(0xFFCF6679),
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark ? OrexColors.darkBg : OrexColors.lightBg,
      fontFamily: 'Inter', // подключите в pubspec; иначе уберите строку
      splashFactory: InkSparkle.splashFactory,
      textTheme: _textTheme(isDark),
      dividerColor: (isDark ? OrexColors.ochre : OrexColors.walnut)
          .withValues(alpha: 0.12),
      iconTheme: IconThemeData(
        color: isDark ? OrexColors.ochreLight : OrexColors.walnut,
      ),
    );
  }

  static TextTheme _textTheme(bool isDark) {
    final base = isDark ? OrexColors.darkText : OrexColors.lightText;
    final soft = isDark ? OrexColors.darkTextSoft : OrexColors.lightTextSoft;
    return TextTheme(
      titleMedium: TextStyle(
          color: base, fontWeight: FontWeight.w600, fontSize: 15.5),
      bodyMedium: TextStyle(color: base, fontSize: 14.5, height: 1.35),
      bodySmall: TextStyle(color: soft, fontSize: 12.5),
      labelLarge: TextStyle(
          color: base, fontWeight: FontWeight.w600, letterSpacing: 0.2),
    );
  }
}
