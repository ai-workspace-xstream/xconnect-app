import 'package:flutter/material.dart';

// ──────────────────────────────────────────────────────────────────
// Semantic color tokens – used throughout the app for consistent
// light/dark mode contrast.  Never hard-code raw hex colors in
// widget code; always pull from Theme.of(context) or these tokens.
//
// Every value below is measured against BOTH light surfaces
// (surface #FFFFFF and cardBackground #F1F3F5) and must reach
// WCAG AA 4.5:1 as text.  See docs/design/ui-style-system.md §10.1
// for the full table.  Re-run the check before changing any of them:
// the smallest margin in the set is 5.13 against 4.5.
// ──────────────────────────────────────────────────────────────────

class AppColors {
  AppColors._();

  // Brand accent – used for links, selection indicators and focus rings.
  // `brandVivid` keeps the original lighter indigo for non-text usage
  // (large fills, illustrations) where the 4.5:1 text rule does not apply.
  static const Color brand = Color(0xFF3F4BA0);
  static const Color brandVivid = Color(0xFF5C6BC0);
  static const Color brandDark = Color(0xFF9FA8DA);

  // Ink – the primary-action surface.  At most one ink block per screen.
  // Dark mode inverts it: the primary action is always the highest
  // contrast block on the screen, whichever way round that lands.
  static const Color ink = Color(0xFF111827);
  static const Color inkPressed = Color(0xFF2B3441);
  static const Color onInk = Color(0xFFFFFFFF);
  static const Color inkDark = Color(0xFFE7E9EA);
  static const Color inkPressedDark = Color(0xFFC9CDD0);
  static const Color onInkDark = Color(0xFF0B0E11);

  // Status semantics – must pass WCAG AA (4.5:1) on both surfaces
  static const Color success = Color(0xFF236B3F);
  static const Color successDark = Color(0xFF5CB978);
  static const Color warning = Color(0xFF8A5200);
  static const Color warningDark = Color(0xFFE0AE5A);
  static const Color error = Color(0xFFB3261E);
  static const Color errorDark = Color(0xFFEF9A9A);

  // Metric accent colors.  These encode information (which direction the
  // traffic flows), so they stay chromatic rather than collapsing to grey –
  // but they still have to clear the same 4.5:1 bar.  The two hues sit
  // ~175° apart so they remain separable under color vision deficiency,
  // and both are always paired with a directional icon and a text label.
  static const Color download = Color(0xFF1F5FBF);
  static const Color downloadDark = Color(0xFF82AAFF);
  static const Color upload = Color(0xFFA83A57);
  static const Color uploadDark = Color(0xFFEF9AAF);
}

/// Corner radius scale.  Two container steps plus a pill – nothing else.
class AppRadius {
  AppRadius._();

  /// Small inset blocks, sunken wells, thumbnails.
  static const double sm = 8;

  /// Cards, dialogs, popovers, inputs.
  static const double card = 16;

  /// Buttons, chips, badges, avatars, the connection FAB.
  static const double pill = 999;
}

/// Motion scale.  Always resolve through [AppMotion.of] so the values
/// collapse to zero when the platform asks for reduced motion.
class AppMotion {
  AppMotion._();

  static const Duration instant = Duration(milliseconds: 120);
  static const Duration quick = Duration(milliseconds: 180);
  static const Duration standard = Duration(milliseconds: 220);
  static const Duration emphasis = Duration(milliseconds: 320);

  /// Returns [duration], or [Duration.zero] when the user has asked the
  /// system to reduce motion.  Animations keep their end state either way.
  static Duration of(BuildContext context, Duration duration) {
    return MediaQuery.maybeDisableAnimationsOf(context) ?? false
        ? Duration.zero
        : duration;
  }
}

/// Theme extension to expose extra semantic colors through the theme.
@immutable
class XConnectColors extends ThemeExtension<XConnectColors> {
  const XConnectColors({
    required this.brand,
    required this.success,
    required this.warning,
    required this.error,
    required this.download,
    required this.upload,
    required this.ink,
    required this.onInk,
    required this.inkPressed,
    required this.cardBackground,
    required this.cardBorder,
    required this.surfaceSunken,
    required this.mutedText,
    required this.subtleText,
    required this.consoleBackground,
    required this.consoleText,
    required this.consoleWarning,
    required this.consoleError,
    required this.warningBannerBackground,
    required this.warningBannerBorder,
    required this.warningBannerText,
  });

  final Color brand;
  final Color success;
  final Color warning;
  final Color error;
  final Color download;
  final Color upload;

  /// Primary-action fill.  At most one per screen.
  final Color ink;
  final Color onInk;
  final Color inkPressed;

  final Color cardBackground;

  /// Kept for callers that still draw a hairline.  Borders are no longer the
  /// default way to separate surfaces – see [surfaceSunken] and
  /// docs/design/ui-style-system.md §6.
  final Color cardBorder;

  /// One step below [cardBackground]: pressed states and wells inside a card.
  final Color surfaceSunken;

  final Color mutedText;
  final Color subtleText;

  /// The log console is a terminal surface: it stays dark in both themes,
  /// so it needs its own tokens rather than borrowing [ink].
  final Color consoleBackground;
  final Color consoleText;
  final Color consoleWarning;
  final Color consoleError;

  final Color warningBannerBackground;
  final Color warningBannerBorder;
  final Color warningBannerText;

  static const light = XConnectColors(
    brand: AppColors.brand,
    success: AppColors.success,
    warning: AppColors.warning,
    error: AppColors.error,
    download: AppColors.download,
    upload: AppColors.upload,
    ink: AppColors.ink,
    onInk: AppColors.onInk,
    inkPressed: AppColors.inkPressed,
    cardBackground: Color(0xFFF1F3F5),
    cardBorder: Color(0xFFE7EAEE),
    surfaceSunken: Color(0xFFE7EAEE),
    mutedText: Color(0xFF4E5A65),
    subtleText: Color(0xFF5B6874),
    consoleBackground: Color(0xFF111827),
    consoleText: Color(0xFFE7E9EA),
    consoleWarning: Color(0xFFE5B15C),
    consoleError: Color(0xFFF2857F),
    warningBannerBackground: Color(0xFFFFF3CD),
    warningBannerBorder: Color(0xFFFFE69C),
    warningBannerText: Color(0xFF664D03),
  );

  static const dark = XConnectColors(
    brand: AppColors.brandDark,
    success: AppColors.successDark,
    warning: AppColors.warningDark,
    error: AppColors.errorDark,
    download: AppColors.downloadDark,
    upload: AppColors.uploadDark,
    ink: AppColors.inkDark,
    onInk: AppColors.onInkDark,
    inkPressed: AppColors.inkPressedDark,
    cardBackground: Color(0xFF191D21),
    cardBorder: Color(0xFF242A31),
    surfaceSunken: Color(0xFF22272C),
    mutedText: Color(0xFFB0B8C8),
    subtleText: Color(0xFF8B95A8),
    consoleBackground: Color(0xFF0B0E11),
    consoleText: Color(0xFFE7E9EA),
    consoleWarning: Color(0xFFE5B15C),
    consoleError: Color(0xFFF2857F),
    warningBannerBackground: Color(0xFF3D3520),
    warningBannerBorder: Color(0xFF5C5030),
    warningBannerText: Color(0xFFFFE082),
  );

  @override
  XConnectColors copyWith({
    Color? brand,
    Color? success,
    Color? warning,
    Color? error,
    Color? download,
    Color? upload,
    Color? ink,
    Color? onInk,
    Color? inkPressed,
    Color? cardBackground,
    Color? cardBorder,
    Color? surfaceSunken,
    Color? mutedText,
    Color? subtleText,
    Color? consoleBackground,
    Color? consoleText,
    Color? consoleWarning,
    Color? consoleError,
    Color? warningBannerBackground,
    Color? warningBannerBorder,
    Color? warningBannerText,
  }) {
    return XConnectColors(
      brand: brand ?? this.brand,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
      download: download ?? this.download,
      upload: upload ?? this.upload,
      ink: ink ?? this.ink,
      onInk: onInk ?? this.onInk,
      inkPressed: inkPressed ?? this.inkPressed,
      cardBackground: cardBackground ?? this.cardBackground,
      cardBorder: cardBorder ?? this.cardBorder,
      surfaceSunken: surfaceSunken ?? this.surfaceSunken,
      mutedText: mutedText ?? this.mutedText,
      subtleText: subtleText ?? this.subtleText,
      consoleBackground: consoleBackground ?? this.consoleBackground,
      consoleText: consoleText ?? this.consoleText,
      consoleWarning: consoleWarning ?? this.consoleWarning,
      consoleError: consoleError ?? this.consoleError,
      warningBannerBackground:
          warningBannerBackground ?? this.warningBannerBackground,
      warningBannerBorder: warningBannerBorder ?? this.warningBannerBorder,
      warningBannerText: warningBannerText ?? this.warningBannerText,
    );
  }

  @override
  XConnectColors lerp(XConnectColors? other, double t) {
    if (other is! XConnectColors) return this;
    return XConnectColors(
      brand: Color.lerp(brand, other.brand, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
      download: Color.lerp(download, other.download, t)!,
      upload: Color.lerp(upload, other.upload, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      onInk: Color.lerp(onInk, other.onInk, t)!,
      inkPressed: Color.lerp(inkPressed, other.inkPressed, t)!,
      cardBackground: Color.lerp(cardBackground, other.cardBackground, t)!,
      cardBorder: Color.lerp(cardBorder, other.cardBorder, t)!,
      surfaceSunken: Color.lerp(surfaceSunken, other.surfaceSunken, t)!,
      mutedText: Color.lerp(mutedText, other.mutedText, t)!,
      subtleText: Color.lerp(subtleText, other.subtleText, t)!,
      consoleBackground:
          Color.lerp(consoleBackground, other.consoleBackground, t)!,
      consoleText: Color.lerp(consoleText, other.consoleText, t)!,
      consoleWarning: Color.lerp(consoleWarning, other.consoleWarning, t)!,
      consoleError: Color.lerp(consoleError, other.consoleError, t)!,
      warningBannerBackground: Color.lerp(
          warningBannerBackground, other.warningBannerBackground, t)!,
      warningBannerBorder:
          Color.lerp(warningBannerBorder, other.warningBannerBorder, t)!,
      warningBannerText:
          Color.lerp(warningBannerText, other.warningBannerText, t)!,
    );
  }
}

/// Convenience extension so any widget can use `context.xColors`.
extension XConnectThemeContext on BuildContext {
  XConnectColors get xColors =>
      Theme.of(this).extension<XConnectColors>() ?? XConnectColors.light;
}

class AppTheme {
  AppTheme._();

  // ── Light ColorScheme ─────────────────────────────────────────
  static const _lightColorScheme = ColorScheme(
    brightness: Brightness.light,
    primary: AppColors.brand,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFE7E9F5),
    onPrimaryContainer: Color(0xFF1A237E),
    secondary: AppColors.download,
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFFDCE6F7),
    onSecondaryContainer: Color(0xFF14375F),
    surface: Colors.white,
    onSurface: Color(0xFF1C1B1F),
    onSurfaceVariant: Color(0xFF4E5A65),
    error: AppColors.error,
    onError: Colors.white,
    outline: Color(0xFF6B7684),
    outlineVariant: Color(0xFFD9DEE4),
    shadow: Color(0x1A000000),
  );

  // ── Dark ColorScheme ──────────────────────────────────────────
  static const _darkColorScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: AppColors.brandDark,
    onPrimary: Color(0xFF1A237E),
    primaryContainer: Color(0xFF3949AB),
    onPrimaryContainer: Color(0xFFE8EAF6),
    secondary: AppColors.downloadDark,
    onSecondary: Color(0xFF0D2147),
    secondaryContainer: Color(0xFF1A3A6B),
    onSecondaryContainer: Color(0xFFD6E4FF),
    surface: Color(0xFF101418),
    onSurface: Color(0xFFE6E1E5),
    onSurfaceVariant: Color(0xFFB0B8C8),
    error: Color(0xFFF2B8B5),
    onError: Color(0xFF601410),
    outline: Color(0xFF8B95A8),
    outlineVariant: Color(0xFF2C333B),
    shadow: Color(0x40000000),
  );

  // ── Shared TextTheme ──────────────────────────────────────────
  // Collected from the sizes that were previously written inline at 53
  // call sites.  The values are unchanged on purpose: this is a move, not
  // a re-scale, so rendering is pixel-identical.  Per-platform type scales
  // become a one-line change once every call site reads from here.
  static TextTheme _textTheme(ColorScheme cs, XConnectColors xc) {
    return TextTheme(
      // Traffic rate readouts.
      displaySmall: TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.8,
        height: 1.0,
        color: cs.onSurface,
      ),
      // Connection state headline.
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        color: cs.onSurface,
      ),
      // Node name.
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
      ),
      // Card headings, AppBar, dialog titles.
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
      ),
      titleSmall: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: cs.onSurface,
      ),
      bodyLarge: TextStyle(fontSize: 15, color: cs.onSurface),
      bodyMedium: TextStyle(fontSize: 14, color: cs.onSurface),
      bodySmall: TextStyle(fontSize: 13, color: xc.mutedText),
      // Metric labels, chips, buttons.
      labelLarge: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
      ),
      // Meta lines, navigation labels.
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: xc.mutedText,
      ),
      labelSmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: xc.subtleText,
      ),
    );
  }

  // ── Focus ring ────────────────────────────────────────────────
  // Desktop keyboard navigation had no visible focus at all.  Every button
  // variant grows the same 2px brand ring when focused.
  static WidgetStateProperty<BorderSide?> _focusSide(
    ColorScheme cs, {
    BorderSide? base,
  }) {
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.focused)) {
        return BorderSide(color: cs.primary, width: 2);
      }
      return base;
    });
  }

  // ── Shared InputDecorationTheme ───────────────────────────────
  // Filled, not outlined: the fill carries the boundary.  Only the focused
  // state draws a stroke, because there it means something.
  static InputDecorationTheme _inputDecoration(
    ColorScheme cs,
    XConnectColors xc,
  ) {
    OutlineInputBorder border(Color color, [double width = 1]) {
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        borderSide: color == Colors.transparent
            ? BorderSide.none
            : BorderSide(color: color, width: width),
      );
    }

    return InputDecorationTheme(
      filled: true,
      fillColor: xc.cardBackground,
      border: border(Colors.transparent),
      enabledBorder: border(Colors.transparent),
      focusedBorder: border(cs.primary, 2),
      disabledBorder: border(Colors.transparent),
      errorBorder: border(cs.error),
      focusedErrorBorder: border(cs.error, 2),
      labelStyle: TextStyle(color: xc.mutedText),
      hintStyle: TextStyle(color: xc.subtleText),
      prefixIconColor: xc.mutedText,
    );
  }

  // ── Shared DialogTheme ────────────────────────────────────────
  static DialogThemeData _dialogTheme(ColorScheme cs) {
    return DialogThemeData(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: cs.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
      contentTextStyle: TextStyle(color: cs.onSurface, fontSize: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    );
  }

  // ── Shared AppBarTheme ────────────────────────────────────────
  static AppBarTheme _appBarTheme(ColorScheme cs, XConnectColors xc) {
    return AppBarTheme(
      backgroundColor: cs.surface,
      foregroundColor: cs.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        color: cs.onSurface,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      iconTheme: IconThemeData(color: xc.mutedText),
    );
  }

  // ── Shared NavigationRailTheme ────────────────────────────────
  // Selection reads as weight, not hue: the selected item switches to the
  // filled icon in the primary text color instead of turning indigo.
  static NavigationRailThemeData _navigationRailTheme(
    ColorScheme cs,
    XConnectColors xc,
  ) {
    return NavigationRailThemeData(
      backgroundColor: cs.surface,
      indicatorColor: xc.surfaceSunken,
      indicatorShape: const StadiumBorder(),
      useIndicator: true,
      selectedIconTheme: IconThemeData(color: cs.onSurface),
      unselectedIconTheme: IconThemeData(color: xc.mutedText),
      selectedLabelTextStyle: TextStyle(
        color: cs.onSurface,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: TextStyle(
        color: xc.mutedText,
        fontSize: 12,
      ),
    );
  }

  // ── Shared NavigationBarTheme ─────────────────────────────────
  // Previously undefined, so mobile fell back to the Material 3 default
  // purple pill while desktop used indigo.  Both now say the same thing.
  static NavigationBarThemeData _navigationBarTheme(
    ColorScheme cs,
    XConnectColors xc,
  ) {
    return NavigationBarThemeData(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: xc.surfaceSunken,
      indicatorShape: const StadiumBorder(),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        return IconThemeData(
          color: states.contains(WidgetState.selected)
              ? cs.onSurface
              : xc.mutedText,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? cs.onSurface : xc.mutedText,
        );
      }),
    );
  }

  // ── Shared CardTheme ──────────────────────────────────────────
  // Fill only: no elevation, no outline.  Depth comes from the surface
  // ramp (surface → cardBackground → surfaceSunken).
  static CardThemeData _cardTheme(XConnectColors xc) {
    return CardThemeData(
      color: xc.cardBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    );
  }

  // ── Shared SnackBarTheme ──────────────────────────────────────
  static SnackBarThemeData _snackBarTheme(ColorScheme cs) {
    return SnackBarThemeData(
      backgroundColor: cs.inverseSurface,
      contentTextStyle: TextStyle(color: cs.onInverseSurface),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    );
  }

  // ── Shared PopupMenuTheme ─────────────────────────────────────
  static PopupMenuThemeData _popupMenuTheme(ColorScheme cs) {
    return PopupMenuThemeData(
      color: cs.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      textStyle: TextStyle(
        fontSize: 15,
        color: cs.onSurface,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  // ── Button themes ─────────────────────────────────────────────
  // Three variants, one job each:
  //   ElevatedButton → ink    (the primary action; at most one per screen)
  //   OutlinedButton → tonal  (secondary; filled, not outlined)
  //   TextButton     → plain  (link-like)
  static ElevatedButtonThemeData _elevatedButtonTheme(
    ColorScheme cs,
    XConnectColors xc,
  ) {
    return ElevatedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return xc.ink.withValues(alpha: 0.38);
          }
          if (states.contains(WidgetState.pressed)) return xc.inkPressed;
          if (states.contains(WidgetState.hovered)) {
            return Color.lerp(xc.ink, xc.inkPressed, 0.5);
          }
          return xc.ink;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.disabled)
              ? xc.onInk.withValues(alpha: 0.62)
              : xc.onInk;
        }),
        iconColor: WidgetStatePropertyAll(xc.onInk),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        shadowColor: const WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: _focusSide(cs),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
    );
  }

  static OutlinedButtonThemeData _outlinedButtonTheme(
    ColorScheme cs,
    XConnectColors xc,
  ) {
    return OutlinedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed) ||
              states.contains(WidgetState.hovered)) {
            return xc.surfaceSunken;
          }
          return xc.cardBackground;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.disabled)
              ? cs.onSurface.withValues(alpha: 0.38)
              : cs.onSurface;
        }),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: _focusSide(cs, base: BorderSide.none),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
    );
  }

  static TextButtonThemeData _textButtonTheme(ColorScheme cs) {
    return TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.disabled)
              ? cs.primary.withValues(alpha: 0.38)
              : cs.primary;
        }),
        overlayColor: WidgetStatePropertyAll(
          cs.primary.withValues(alpha: 0.10),
        ),
        side: _focusSide(cs),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }

  // ── Shared FloatingActionButtonTheme ──────────────────────────
  static FloatingActionButtonThemeData _fabTheme(XConnectColors xc) {
    return FloatingActionButtonThemeData(
      backgroundColor: xc.ink,
      foregroundColor: xc.onInk,
      elevation: 3,
      focusElevation: 3,
      hoverElevation: 4,
      highlightElevation: 2,
      extendedTextStyle: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      shape: const StadiumBorder(),
    );
  }

  // ── Shared ChipTheme ──────────────────────────────────────────
  static ChipThemeData _chipTheme(ColorScheme cs, XConnectColors xc) {
    return ChipThemeData(
      backgroundColor: xc.cardBackground,
      selectedColor: xc.surfaceSunken,
      disabledColor: xc.cardBackground,
      surfaceTintColor: Colors.transparent,
      side: BorderSide.none,
      showCheckmark: false,
      elevation: 0,
      pressElevation: 0,
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
      ),
      shape: const StadiumBorder(),
    );
  }

  // ── Shared ListTileTheme ──────────────────────────────────────
  static ListTileThemeData _listTileTheme(ColorScheme cs, XConnectColors xc) {
    return ListTileThemeData(
      textColor: cs.onSurface,
      iconColor: xc.mutedText,
      subtitleTextStyle: TextStyle(color: xc.mutedText, fontSize: 12),
    );
  }

  static ThemeData _build({
    required Brightness brightness,
    required ColorScheme cs,
    required XConnectColors xc,
  }) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: cs,
      scaffoldBackgroundColor: cs.surface,
      textTheme: _textTheme(cs, xc),
      appBarTheme: _appBarTheme(cs, xc),
      inputDecorationTheme: _inputDecoration(cs, xc),
      dialogTheme: _dialogTheme(cs),
      navigationRailTheme: _navigationRailTheme(cs, xc),
      navigationBarTheme: _navigationBarTheme(cs, xc),
      cardTheme: _cardTheme(xc),
      snackBarTheme: _snackBarTheme(cs),
      popupMenuTheme: _popupMenuTheme(cs),
      elevatedButtonTheme: _elevatedButtonTheme(cs, xc),
      outlinedButtonTheme: _outlinedButtonTheme(cs, xc),
      textButtonTheme: _textButtonTheme(cs),
      floatingActionButtonTheme: _fabTheme(xc),
      chipTheme: _chipTheme(cs, xc),
      listTileTheme: _listTileTheme(cs, xc),
      dividerTheme: DividerThemeData(color: cs.outlineVariant, thickness: 1),
      extensions: <ThemeExtension<dynamic>>[xc],
    );
  }

  // ── LIGHT THEME ───────────────────────────────────────────────
  static final ThemeData lightTheme = _build(
    brightness: Brightness.light,
    cs: _lightColorScheme,
    xc: XConnectColors.light,
  );

  // ── DARK THEME ────────────────────────────────────────────────
  static final ThemeData darkTheme = _build(
    brightness: Brightness.dark,
    cs: _darkColorScheme,
    xc: XConnectColors.dark,
  );
}
