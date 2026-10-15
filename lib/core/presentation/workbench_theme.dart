import 'package:flutter/material.dart';

ThemeData workbenchTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xff007aff),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xff0a84ff) : const Color(0xff007aff),
        onPrimary: Colors.white,
        secondary: dark ? const Color(0xff0a84ff) : const Color(0xff007aff),
        onSecondary: Colors.white,
        secondaryContainer: dark
            ? const Color(0xff173552)
            : const Color(0xffe5f0ff),
        onSecondaryContainer: dark
            ? const Color(0xffb9daff)
            : const Color(0xff0062cc),
        surface: dark ? const Color(0xff1c1c1e) : Colors.white,
        surfaceContainerLowest: dark ? const Color(0xff18181a) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xff242426)
            : const Color(0xfff5f5f7),
        surfaceContainer: dark
            ? const Color(0xff29292c)
            : const Color(0xfffafafa),
        surfaceContainerHigh: dark
            ? const Color(0xff303033)
            : const Color(0xfff0f0f2),
        surfaceContainerHighest: dark
            ? const Color(0xff353538)
            : const Color(0xffededf0),
        primaryContainer: dark
            ? const Color(0xff173552)
            : const Color(0xffe5f0ff),
        onPrimaryContainer: dark
            ? const Color(0xffb9daff)
            : const Color(0xff0062cc),
        onSurface: dark ? const Color(0xfff2f2f4) : const Color(0xff1d1d1f),
        onSurfaceVariant: dark
            ? const Color(0xffa1a1aa)
            : const Color(0xff6e6e73),
        outline: dark ? const Color(0xff56565b) : const Color(0xffc5c5cb),
        outlineVariant: dark
            ? const Color(0xff38383b)
            : const Color(0xffe3e3e8),
        error: dark ? const Color(0xffff827b) : const Color(0xffc9342c),
      );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: scheme.outlineVariant),
  );
  final theme = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: '.AppleSystemUIFont',
    fontFamilyFallback: const [
      'SF Pro Text',
      'PingFang SC',
      'Segoe UI',
      'Arial',
    ],
    visualDensity: VisualDensity.compact,
  );
  return theme.copyWith(
    textTheme: theme.textTheme.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainer,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      border: border,
      enabledBorder: border,
      disabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        elevation: 0,
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: theme.textTheme.labelLarge?.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        minimumSize: const Size(0, 36),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 13),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: .18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      textStyle: theme.textTheme.bodyMedium?.copyWith(
        fontSize: 13,
        color: scheme.onSurface,
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant,
      indicatorColor: scheme.primary,
      dividerColor: scheme.outlineVariant,
      labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
    ),
  );
}
