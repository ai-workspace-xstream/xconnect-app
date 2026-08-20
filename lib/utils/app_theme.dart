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

  // Brand primary – Refined Tech Blue (科技简约蓝 #1D5BD8 / #1E4FB8), calm and sophisticated.
  static const Color brand = Color(0xFF1D5BD8);
  static const Color brandHover = Color(0xFF1548B0);
  static const Color brandMuted = Color(0xFFF0F5FF);
  static const Color brandBorder = Color(0xFFD6E4FA);
  static const Color brandVivid = Color(0xFF3B82F6);
  static const Color brandDark = Color(0xFF60A5FA);
  static const Color brandDarkMuted = Color(0xFF172554);

  // Ink – primary-action surface (Tech Blue in light, Sky in dark).
  static const Color ink = Color(0xFF1D5BD8);
  static const Color inkPressed = Color(0xFF1548B0);
  static const Color onInk = Color(0xFFFFFFFF);
  static const Color inkDark = Color(0xFF60A5FA);
  static const Color inkPressedDark = Color(0xFF3B82F6);
  static const Color onInkDark = Color(0xFF0F172A);

  // Status semantics – calm, natural, non-glaring tones
  // Success / Connected: Refined Emerald / Forest Green (#15803D)
  static const Color success = Color(0xFF15803D);
  static const Color successMuted = Color(0xFFEBFDF3);
  static const Color successForeground = Color(0xFF14532D);
  static const Color successDark = Color(0xFF4ADE80);
  static const Color successDarkMuted = Color(0xFF133E26);

  // Warning: Low-saturation Amber (#B45309) with soft tint (#FEF3C7)
  static const Color warning = Color(0xFFB45309);
  static const Color warningMuted = Color(0xFFFEF3C7);
  static const Color warningForeground = Color(0xFF78350F);
  static const Color warningDark = Color(0xFFFBBF24);

  // Error: Muted Crimson (#DC2626) with soft tint (#FEE2E2)
  static const Color error = Color(0xFFDC2626);
  static const Color errorMuted = Color(0xFFFEE2E2);
  static const Color errorForeground = Color(0xFF991B1B);
  static const Color errorDark = Color(0xFFF87171);

  // Metric accent colors (download = Tech Blue, upload = Refined Violet)
  static const Color download = Color(0xFF1D5BD8);
  static const Color downloadDark = Color(0xFF60A5FA);
  static const Color upload = Color(0xFF7C3AED);
  static const Color uploadDark = Color(0xFFA78BFA);
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
    required this.brandMuted,
    required this.brandBorder,
    required this.success,
    required this.successMuted,
    required this.successForeground,
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
  final Color brandMuted;
  final Color brandBorder;
  final Color success;
  final Color successMuted;
  final Color successForeground;
  final Color warning;
  final Color error;
  final Color download;
  final Color upload;

  /// Primary-action fill.
  final Color ink;
  final Color onInk;
  final Color inkPressed;

  final Color cardBackground;
  final Color cardBorder;
  final Color surfaceSunken;

  final Color mutedText;
  final Color subtleText;

  /// The log console terminal colors
  final Color consoleBackground;
  final Color consoleText;
  final Color consoleWarning;
  final Color consoleError;

  final Color warningBannerBackground;
  final Color warningBannerBorder;
  final Color warningBannerText;

  static const light = XConnectColors(
    brand: AppColors.brand,
    brandMuted: AppColors.brandMuted,
    brandBorder: AppColors.brandBorder,
    success: AppColors.success,
    successMuted: AppColors.successMuted,
    successForeground: AppColors.successForeground,
    warning: AppColors.warning,
    error: AppColors.error,
    download: AppColors.download,
    upload: AppColors.upload,
    ink: AppColors.ink,
    onInk: AppColors.onInk,
    inkPressed: AppColors.inkPressed,
    cardBackground: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFE2E8F0),
    surfaceSunken: Color(0xFFF1F5F9),
    mutedText: Color(0xFF475569),
    subtleText: Color(0xFF94A3B8),
    consoleBackground: Color(0xFF0F172A),
    consoleText: Color(0xFFE2E8F0),
    consoleWarning: Color(0xFFFBBF24),
    consoleError: Color(0xFFF87171),
    warningBannerBackground: Color(0xFFFEF3C7),
    warningBannerBorder: Color(0xFFFDE68A),
    warningBannerText: Color(0xFF78350F),
  );

  static const dark = XConnectColors(
    brand: AppColors.brandDark,
    brandMuted: AppColors.brandDarkMuted,
    brandBorder: Color(0xFF1E3A5F),
    success: AppColors.successDark,
    successMuted: AppColors.successDarkMuted,
    successForeground: Color(0xFF86EFAC),
    warning: AppColors.warningDark,
    error: AppColors.errorDark,
    download: AppColors.downloadDark,
    upload: AppColors.uploadDark,
    ink: AppColors.inkDark,
    onInk: AppColors.onInkDark,
    inkPressed: AppColors.inkPressedDark,
    cardBackground: Color(0xFF131B26),
    cardBorder: Color(0xFF243042),
    surfaceSunken: Color(0xFF1A2433),
    mutedText: Color(0xFF94A3B8),
    subtleText: Color(0xFF64748B),
    consoleBackground: Color(0xFF0B0F17),
    consoleText: Color(0xFFE2E8F0),
    consoleWarning: Color(0xFFFBBF24),
    consoleError: Color(0xFFF87171),
    warningBannerBackground: Color(0xFF332A18),
    warningBannerBorder: Color(0xFF524220),
    warningBannerText: Color(0xFFFDE68A),
  );

  @override
  XConnectColors copyWith({
    Color? brand,
    Color? brandMuted,
    Color? brandBorder,
    Color? success,
    Color? successMuted,
    Color? successForeground,
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
      brandMuted: brandMuted ?? this.brandMuted,
      brandBorder: brandBorder ?? this.brandBorder,
      success: success ?? this.success,
      successMuted: successMuted ?? this.successMuted,
      successForeground: successForeground ?? this.successForeground,
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
      brandMuted: Color.lerp(brandMuted, other.brandMuted, t)!,
      brandBorder: Color.lerp(brandBorder, other.brandBorder, t)!,
      success: Color.lerp(success, other.success, t)!,
      successMuted: Color.lerp(successMuted, other.successMuted, t)!,
      successForeground:
          Color.lerp(successForeground, other.successForeground, t)!,
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
    primaryContainer: AppColors.brandMuted,
    onPrimaryContainer: AppColors.brand,
    secondary: AppColors.brandVivid,
    onSecondary: Colors.white,
    secondaryContainer: AppColors.brandMuted,
    onSecondaryContainer: Color(0xFF1E3A8A),
    surface: Color(0xFFF8FAFC),
    onSurface: Color(0xFF0F172A),
    onSurfaceVariant: Color(0xFF475569),
    error: AppColors.error,
    onError: Colors.white,
    outline: Color(0xFF94A3B8),
    outlineVariant: Color(0xFFE2E8F0),
    shadow: Color(0x0A0F172A),
  );

  // ── Dark ColorScheme ──────────────────────────────────────────
  static const _darkColorScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: AppColors.brandDark,
    onPrimary: Color(0xFF0B0F17),
    primaryContainer: Color(0xFF172554),
    onPrimaryContainer: Color(0xFFD6E4FF),
    secondary: AppColors.brandVivid,
    onSecondary: Color(0xFF0D2147),
    secondaryContainer: Color(0xFF1A3A6B),
    onSecondaryContainer: Color(0xFFD6E4FF),
    surface: Color(0xFF0B0F17),
    onSurface: Color(0xFFF1F5F9),
    onSurfaceVariant: Color(0xFF94A3B8),
    error: Color(0xFFF87171),
    onError: Color(0xFF601410),
    outline: Color(0xFF64748B),
    outlineVariant: Color(0xFF243042),
    shadow: Color(0x40000000),
  );

  // ── Shared TextTheme ──────────────────────────────────────────
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
      border: border(xc.cardBorder),
      enabledBorder: border(xc.cardBorder),
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
  static DialogThemeData _dialogTheme(ColorScheme cs, XConnectColors xc) {
    return DialogThemeData(
      backgroundColor: xc.cardBackground,
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
  static NavigationRailThemeData _navigationRailTheme(
    ColorScheme cs,
    XConnectColors xc,
  ) {
    return NavigationRailThemeData(
      backgroundColor: cs.surface,
      indicatorColor: xc.brandMuted,
      indicatorShape: const StadiumBorder(),
      useIndicator: true,
      selectedIconTheme: IconThemeData(color: cs.primary),
      unselectedIconTheme: IconThemeData(color: xc.mutedText),
      selectedLabelTextStyle: TextStyle(
        color: cs.primary,
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
  static NavigationBarThemeData _navigationBarTheme(
    ColorScheme cs,
    XConnectColors xc,
  ) {
    return NavigationBarThemeData(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: xc.brandMuted,
      indicatorShape: const StadiumBorder(),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        return IconThemeData(
          color:
              states.contains(WidgetState.selected) ? cs.primary : xc.mutedText,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? cs.primary : xc.mutedText,
        );
      }),
    );
  }

  // ── Shared CardTheme ──────────────────────────────────────────
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
  static PopupMenuThemeData _popupMenuTheme(ColorScheme cs, XConnectColors xc) {
    return PopupMenuThemeData(
      color: xc.cardBackground,
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
  static ElevatedButtonThemeData _elevatedButtonTheme(
    ColorScheme cs,
    XConnectColors xc,
  ) {
    return ElevatedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return cs.primary.withValues(alpha: 0.38);
          }
          if (states.contains(WidgetState.pressed)) return AppColors.brandHover;
          if (states.contains(WidgetState.hovered)) {
            return Color.lerp(cs.primary, AppColors.brandHover, 0.5);
          }
          return cs.primary;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.disabled)
              ? Colors.white.withValues(alpha: 0.62)
              : Colors.white;
        }),
        iconColor: const WidgetStatePropertyAll(Colors.white),
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

  static FilledButtonThemeData _filledButtonTheme(
    ColorScheme cs,
    XConnectColors xc,
  ) {
    return FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return cs.primary.withValues(alpha: 0.38);
          }
          if (states.contains(WidgetState.pressed)) return AppColors.brandHover;
          if (states.contains(WidgetState.hovered)) {
            return Color.lerp(cs.primary, AppColors.brandHover, 0.5);
          }
          return cs.primary;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.disabled)
              ? Colors.white.withValues(alpha: 0.62)
              : Colors.white;
        }),
        iconColor: const WidgetStatePropertyAll(Colors.white),
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
        side: _focusSide(cs, base: BorderSide(color: xc.cardBorder)),
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
  static FloatingActionButtonThemeData _fabTheme(
    ColorScheme cs,
    XConnectColors xc,
  ) {
    return FloatingActionButtonThemeData(
      backgroundColor: cs.primary,
      foregroundColor: Colors.white,
      elevation: 2,
      focusElevation: 2,
      hoverElevation: 3,
      highlightElevation: 1,
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
      backgroundColor: xc.surfaceSunken,
      selectedColor: xc.brandMuted,
      disabledColor: xc.surfaceSunken,
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
      dialogTheme: _dialogTheme(cs, xc),
      navigationRailTheme: _navigationRailTheme(cs, xc),
      navigationBarTheme: _navigationBarTheme(cs, xc),
      cardTheme: _cardTheme(xc),
      snackBarTheme: _snackBarTheme(cs),
      popupMenuTheme: _popupMenuTheme(cs, xc),
      elevatedButtonTheme: _elevatedButtonTheme(cs, xc),
      filledButtonTheme: _filledButtonTheme(cs, xc),
      outlinedButtonTheme: _outlinedButtonTheme(cs, xc),
      textButtonTheme: _textButtonTheme(cs),
      floatingActionButtonTheme: _fabTheme(cs, xc),
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
