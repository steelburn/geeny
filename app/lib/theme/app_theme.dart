import 'package:flutter/material.dart';

import 'tokens.dart';

ThemeData buildTheme() {
  // Every interactive surface declares its states here so no widget has to
  // hand-roll hover / pressed / focus / disabled behaviour.
  WidgetStateProperty<T> byState<T>({
    required T base,
    required T hover,
    required T pressed,
    required T disabled,
    required T focus,
  }) =>
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return disabled;
        if (states.contains(WidgetState.pressed)) return pressed;
        if (states.contains(WidgetState.hovered)) return hover;
        if (states.contains(WidgetState.focused)) return focus;
        return base;
      });

  final flat = ButtonStyle(
    textStyle: WidgetStateProperty.all(Tokens.body.copyWith(fontWeight: FontWeight.w600)),
    padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: Tokens.s4, vertical: 13)),
    minimumSize: WidgetStateProperty.all(const Size(0, 46)),
    shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(Tokens.r2))),
    elevation: WidgetStateProperty.all(0),
    animationDuration: const Duration(milliseconds: 120),
    overlayColor: WidgetStateProperty.all(Colors.transparent),
    side: byState<BorderSide>(
      base: const BorderSide(color: Tokens.ruleStrong),
      hover: const BorderSide(color: Tokens.inkSoft),
      pressed: const BorderSide(color: Tokens.inkSoft),
      disabled: const BorderSide(color: Tokens.rule),
      focus: const BorderSide(color: Tokens.accent, width: 2),
    ),
    backgroundColor: byState(
      base: Tokens.surface,
      hover: const Color(0xFFFFFFFF),
      pressed: Tokens.accentSoft,
      disabled: Tokens.surface,
      focus: Tokens.surface,
    ),
    foregroundColor: byState(
      base: Tokens.ink,
      hover: Tokens.ink,
      pressed: Tokens.ink,
      disabled: Tokens.inkSoft.withValues(alpha: 0.45),
      focus: Tokens.ink,
    ),
  );

  final primary = flat.copyWith(
    side: byState<BorderSide>(
      base: const BorderSide(color: Tokens.accent),
      hover: const BorderSide(color: Tokens.accentPressed),
      pressed: const BorderSide(color: Tokens.accentPressed),
      disabled: const BorderSide(color: Tokens.rule),
      focus: const BorderSide(color: Tokens.ink, width: 2),
    ),
    backgroundColor: byState(
      base: Tokens.accent,
      hover: Tokens.accentPressed,
      pressed: const Color(0xFF0F3829),
      disabled: Tokens.accentSoft,
      focus: Tokens.accent,
    ),
    foregroundColor: byState(
      base: Tokens.onAccent,
      hover: Tokens.onAccent,
      pressed: Tokens.onAccent,
      disabled: Tokens.inkSoft.withValues(alpha: 0.45),
      focus: Tokens.onAccent,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    fontFamily: Tokens.sans,
    scaffoldBackgroundColor: Tokens.paper,
    canvasColor: Tokens.paper,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Tokens.accent,
      brightness: Brightness.light,
      surface: Tokens.paper,
      primary: Tokens.accent,
      error: Tokens.danger,
    ),
    splashFactory: NoSplash.splashFactory,
    textTheme: TextTheme(
      displayLarge: Tokens.display,
      titleMedium: Tokens.title,
      bodyMedium: Tokens.body,
      bodySmall: Tokens.bodySmall,
      labelSmall: Tokens.section,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        textStyle: primary.textStyle,
        padding: primary.padding,
        minimumSize: primary.minimumSize,
        shape: primary.shape,
        elevation: primary.elevation,
        animationDuration: primary.animationDuration,
        overlayColor: primary.overlayColor,
        side: primary.side,
        backgroundColor: primary.backgroundColor,
        foregroundColor: primary.foregroundColor,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(style: flat),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Tokens.accent,
        textStyle: Tokens.bodySmall.copyWith(color: Tokens.accent, fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: Tokens.s2, vertical: Tokens.s1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Tokens.r1)),
        overlayColor: Tokens.accentSoft,
      ),
    ),
    dividerTheme: const DividerThemeData(color: Tokens.rule, thickness: 1, space: 1),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Tokens.accent,
      linearMinHeight: 3,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: Tokens.ink, borderRadius: BorderRadius.circular(Tokens.r1)),
      textStyle: Tokens.caption.copyWith(color: Tokens.paper),
      waitDuration: const Duration(milliseconds: 500),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Tokens.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: Tokens.s3, vertical: Tokens.s3),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.r2),
        borderSide: const BorderSide(color: Tokens.rule),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.r2),
        borderSide: const BorderSide(color: Tokens.ruleStrong),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.r2),
        borderSide: const BorderSide(color: Tokens.accent, width: 2),
      ),
    ),
  );
}
