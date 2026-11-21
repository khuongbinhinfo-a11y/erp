import 'package:material_ui/material_ui.dart';

/// ERP-only semantic palette; no assets or branded colors copied from references.
abstract final class ErpTokens {
  static const Color primary = Color(0xFF164E35);
  static const Color primaryHover = Color(0xFF103D2A);
  static const Color canvas = Color(0xFFF5F7F2);
  static const Color surface = Color(0xFFFCFDF9);
  static const Color mint = Color(0xFFE8F3EB);
  static const Color border = Color(0xFFDCE5DC);
  static const Color ink = Color(0xFF1B3328);
  static const Color muted = Color(0xFF627267);
  static const Color danger = Color(0xFFB42318);
  static const Color warning = Color(0xFF9A6700);
  static const double desktopButton = 36;
  static const double mobileButton = 44;
  static const double fieldHeight = 40;
  static const double controlFont = 13;
  static const double controlRadius = 6;
  static const double cardRadius = 7;
  static const Color fresh = Color(0xFF27B97B);
  static const Color lime = Color(0xFFD7EF8A);
  static const Color sidebar = Color(0xFF102E24);
  static const Color sidebarBottom = Color(0xFF164E35);
  static const Color sidebarText = Color(0xFFE0F1E7);
  static const Duration toastDuration = Duration(seconds: 4);
  static const Duration buttonMotion = Duration(milliseconds: 190);
  static const Duration menuMotion = Duration(milliseconds: 200);
  static const Duration popupOpenMotion = Duration(milliseconds: 280);
  static const Duration popupCloseMotion = Duration(milliseconds: 220);
  static const Duration drawerMotion = Duration(milliseconds: 300);
  static const Duration tabMotion = Duration(milliseconds: 180);
  static const Duration pageMotion = Duration(milliseconds: 160);
}

ThemeData erpTheme({required bool touch}) {
  final buttonHeight = touch ? ErpTokens.mobileButton : ErpTokens.desktopButton;
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(ErpTokens.controlRadius),
  );
  final buttonStyle = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(0, buttonHeight)),
    textStyle: const WidgetStatePropertyAll(
      TextStyle(fontSize: ErpTokens.controlFont, fontWeight: FontWeight.w600),
    ),
    shape: WidgetStatePropertyAll(shape),
    animationDuration: ErpTokens.buttonMotion,
  );
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: ErpTokens.canvas,
    colorScheme: ColorScheme.fromSeed(seedColor: ErpTokens.primary).copyWith(
      primary: ErpTokens.primary,
      secondary: ErpTokens.fresh,
      onPrimary: Colors.white,
      surface: ErpTokens.surface,
      onSurface: ErpTokens.ink,
      error: ErpTokens.danger,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: ErpTokens.surface,
      foregroundColor: ErpTokens.ink,
      elevation: 0,
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle),
    textButtonTheme: TextButtonThemeData(style: buttonStyle),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ErpTokens.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ErpTokens.controlRadius),
        borderSide: const BorderSide(color: ErpTokens.border),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      constraints: const BoxConstraints(minHeight: ErpTokens.fieldHeight),
    ),
    cardTheme: CardThemeData(
      color: ErpTokens.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ErpTokens.cardRadius),
        side: const BorderSide(color: ErpTokens.border),
      ),
    ),
  );
}
