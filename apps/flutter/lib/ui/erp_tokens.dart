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

/// Context-scoped semantic colors. Brand surfaces keep their own foregrounds.
/// Never mutate static tokens when changing theme: overlays and multiple
/// mounted workspaces must resolve colors from their own inherited Theme.
class ErpPalette {
  final bool dark;
  const ErpPalette(this.dark);
  static ErpPalette of(BuildContext context) =>
      ErpPalette(Theme.of(context).brightness == Brightness.dark);
  Color get canvas => dark ? const Color(0xFF141A17) : ErpTokens.canvas;
  Color get surface => dark ? const Color(0xFF1D2721) : ErpTokens.surface;
  Color get popup => dark ? const Color(0xFF26332B) : ErpTokens.surface;
  Color get mint => dark ? const Color(0xFF26392C) : ErpTokens.mint;
  Color get border => dark ? const Color(0xFF65776A) : ErpTokens.border;
  // Separators may be subtle; interactive control boundaries meet 3:1.
  Color get controlBorder => dark ? const Color(0xFF819287) : const Color(0xFF7B8A7D);
  Color get ink => dark ? const Color(0xFFDCE5DE) : ErpTokens.ink;
  Color get muted => dark ? const Color(0xFFA1B2A7) : const Color(0xFF5C6D62);
  Color get primary => dark ? const Color(0xFF9CDDB0) : ErpTokens.primary;
  Color get action => dark ? const Color(0xFF326443) : ErpTokens.primary;
  Color get onAction => const Color(0xFFEEF5EF);
  Color get danger => dark ? const Color(0xFFF0A39E) : ErpTokens.danger;
  Color get warning => dark ? const Color(0xFFDEC083) : const Color(0xFF8C5D00);
  Color get fresh => dark ? const Color(0xFF8DCF9F) : const Color(0xFF236B3B);
  Color get sidebar => dark ? const Color(0xFF192A21) : ErpTokens.sidebar;
  Color get sidebarBottom => dark ? const Color(0xFF203529) : ErpTokens.sidebarBottom;
  Color get sidebarActive => dark ? const Color(0xFF294D38) : const Color(0xFFC5E1CB);
  Color get onSidebarActive => dark ? const Color(0xFFBDE8CA) : ErpTokens.primary;
}

ThemeData erpTheme({required bool touch, bool dark = false}) {
  final p = ErpPalette(dark);
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
  final scheme = ColorScheme.fromSeed(
    seedColor: ErpTokens.primary,
    brightness: dark ? Brightness.dark : Brightness.light,
  ).copyWith(
    primary: p.primary, onPrimary: dark ? const Color(0xFF173324) : Colors.white,
    secondary: p.fresh, surface: p.surface, onSurface: p.ink,
    onSurfaceVariant: p.muted, outline: p.controlBorder, outlineVariant: p.border,
    inverseSurface:p.popup,onInverseSurface:p.ink,inversePrimary:p.primary,
    surfaceContainerLowest: p.canvas, surfaceContainerLow: p.surface,
    surfaceContainer: p.popup, surfaceContainerHigh: p.popup,
    surfaceContainerHighest: p.mint, error: p.danger,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.canvas,
    canvasColor: p.surface,
    dividerColor: p.border,
    appBarTheme: AppBarTheme(
      backgroundColor: p.surface, foregroundColor: p.ink,
      surfaceTintColor: Colors.transparent, elevation: 0,
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttonStyle.copyWith(
      backgroundColor: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.disabled) ? p.mint : p.action),
      foregroundColor: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.disabled) ? p.muted : p.onAction),
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle.copyWith(
      side:WidgetStateProperty.resolveWith((states)=>BorderSide(
        color:states.contains(WidgetState.focused)?p.primary:p.controlBorder)),
    )),
    textButtonTheme: TextButtonThemeData(style: buttonStyle),
    dialogTheme: DialogThemeData(backgroundColor: p.popup,
      surfaceTintColor: Colors.transparent),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.popup,
      modalBackgroundColor: p.popup, surfaceTintColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(color: p.popup,
      surfaceTintColor: Colors.transparent),
    tooltipTheme: TooltipThemeData(
      decoration:BoxDecoration(color:p.popup,border:Border.all(color:p.controlBorder),borderRadius:BorderRadius.circular(6)),
      textStyle:TextStyle(color:p.ink,fontSize:12),
    ),
    snackBarTheme: SnackBarThemeData(backgroundColor:p.popup,
      contentTextStyle:TextStyle(color:p.ink),actionTextColor:p.primary),
    datePickerTheme:DatePickerThemeData(backgroundColor:p.popup,surfaceTintColor:Colors.transparent),
    timePickerTheme:TimePickerThemeData(backgroundColor:p.popup),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.surface, indicatorColor: p.mint,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
        color: states.contains(WidgetState.selected) ? p.primary : p.muted,
        fontSize: 11, fontWeight: states.contains(WidgetState.selected)
          ? FontWeight.w700 : FontWeight.w500)),
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
        color: states.contains(WidgetState.selected) ? p.primary : p.muted)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: p.surface,
      hintStyle: TextStyle(color: p.muted),
      labelStyle: TextStyle(color: p.muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ErpTokens.controlRadius),
        borderSide: BorderSide(color: p.controlBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ErpTokens.controlRadius),
        borderSide: BorderSide(color: p.controlBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ErpTokens.controlRadius),
        borderSide: BorderSide(color: p.primary, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      constraints: BoxConstraints(minHeight: touch ? 44 : ErpTokens.fieldHeight),
    ),
    cardTheme: CardThemeData(
      color: p.surface, surfaceTintColor: Colors.transparent, elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ErpTokens.cardRadius),
        side: BorderSide(color: p.border),
      ),
    ),
  );
}

/// Shared selector for desktop, mobile settings and the login page.
class ErpThemeSelector extends StatelessWidget {
  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;
  const ErpThemeSelector({super.key, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => PopupMenuButton<ThemeMode>(
    key: const ValueKey('erp-theme-selector'),
    tooltip: 'Giao diện',
    icon: Icon(Theme.of(context).brightness == Brightness.dark
      ? Icons.dark_mode_outlined : Icons.light_mode_outlined),
    initialValue: value,
    onSelected: onChanged,
    itemBuilder: (_) => const [
      PopupMenuItem(value: ThemeMode.system, child: Text('Theo thiết bị')),
      PopupMenuItem(value: ThemeMode.light, child: Text('Sáng')),
      PopupMenuItem(value: ThemeMode.dark, child: Text('Tối')),
    ],
  );
}
