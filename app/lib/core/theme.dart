import 'package:material_ui/material_ui.dart';

/// 디자인 목업(/mnt/project-files/design/fitlog-mockup.html)의 색 토큰.
/// 색은 의미에만 쓴다: accent=오늘·행동·현재 세트, last=지난 세션, pr=개인 최고기록,
/// fail=목표 미달(항상 아이콘·숫자 동반), warn=디로드·주의, ai=AI 출처.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.accent,
    required this.accentStrong,
    required this.onAccent,
    required this.accentSoft,
    required this.last,
    required this.pr,
    required this.prSoft,
    required this.fail,
    required this.failSoft,
    required this.warn,
    required this.warnSoft,
    required this.ai,
    required this.aiSoft,
    required this.surface2,
    required this.surface3,
    required this.line,
    required this.fg,
    required this.fg2,
  });

  final Color accent, accentStrong, onAccent, accentSoft;
  final Color last;
  final Color pr, prSoft;
  final Color fail, failSoft;
  final Color warn, warnSoft;
  final Color ai, aiSoft;

  /// surface2: 카드 안쪽 옅은 채움, surface3: 칩·구분 채움, line: 테두리.
  final Color surface2, surface3, line;

  /// fg: 본문, fg2: 보조 글씨.
  final Color fg, fg2;

  static const light = AppColors(
    accent: Color(0xFF2E7D5B),
    accentStrong: Color(0xFF1F5E43),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFDCEFE5),
    last: Color(0xFF7D8A84),
    pr: Color(0xFFB7791F),
    prSoft: Color(0xFFFBEFD9),
    fail: Color(0xFFC2410C),
    failSoft: Color(0xFFFDE7DC),
    warn: Color(0xFF9A6700),
    warnSoft: Color(0xFFFFF3D1),
    ai: Color(0xFF3B5BDB),
    aiSoft: Color(0xFFE3E9FF),
    surface2: Color(0xFFF3F6F4),
    surface3: Color(0xFFE4EAE6),
    line: Color(0xFFD3DBD6),
    fg: Color(0xFF17201B),
    fg2: Color(0xFF4A5750),
  );

  static const dark = AppColors(
    accent: Color(0xFF5CC395),
    accentStrong: Color(0xFF8BDDB6),
    onAccent: Color(0xFF06261A),
    accentSoft: Color(0xFF183A2B),
    last: Color(0xFF8A9790),
    pr: Color(0xFFE3A43A),
    prSoft: Color(0xFF3A2C12),
    fail: Color(0xFFFF8A5B),
    failSoft: Color(0xFF3D1F13),
    warn: Color(0xFFE8B53A),
    warnSoft: Color(0xFF33290F),
    ai: Color(0xFF8FA6FF),
    aiSoft: Color(0xFF1E2747),
    surface2: Color(0xFF1B241F),
    surface3: Color(0xFF26312B),
    line: Color(0xFF2F3B35),
    fg: Color(0xFFE6EDE9),
    fg2: Color(0xFFA3B1AA),
  );

  /// 위젯에서: `AppColors.of(context).pr`
  static AppColors of(BuildContext context) => Theme.of(context).extension<AppColors>() ?? light;

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(AppColors? other, double t) => t < 0.5 || other == null ? this : other;
}

/// 큰 숫자(무게·횟수·타이머·볼륨)용 글꼴. 표의 숫자도 자릿수가 맞게 tabular.
abstract final class AppNum {
  static const family = 'BarlowSemiCondensed';
  static const _tab = [FontFeature.tabularFigures()];

  /// 예: `AppNum.style(context, 40)` → 40px SemiBold, 본문 색.
  static TextStyle style(BuildContext context, double size, {FontWeight weight = FontWeight.w600, Color? color}) =>
      TextStyle(
        fontFamily: family,
        fontSize: size,
        fontWeight: weight,
        height: 1.1,
        fontFeatures: _tab,
        color: color ?? AppColors.of(context).fg,
      );

  /// 자주 쓰는 크기: hero(타이머·현재 세트 무게) 56, large(카드 메인 무게) 36, medium 24, table(표 숫자) 16.
  static TextStyle hero(BuildContext c, {Color? color}) => style(c, 56, weight: FontWeight.w700, color: color);
  static TextStyle large(BuildContext c, {Color? color}) => style(c, 36, color: color);
  static TextStyle medium(BuildContext c, {Color? color}) => style(c, 24, color: color);
  static TextStyle table(BuildContext c, {Color? color}) => style(c, 16, weight: FontWeight.w500, color: color);
}

/// 모서리 반경(목업 --r-sm/md/lg).
abstract final class AppRadius {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 20.0;
}

/// 시스템 설정을 따르는 라이트/다크 테마. Material 3, seed #2E7D5B.
abstract final class AppTheme {
  static const _seed = Color(0xFF2E7D5B);
  static const uiFamily = 'IBMPlexSansKR';

  static ThemeData light() => _build(Brightness.light, AppColors.light);
  static ThemeData dark() => _build(Brightness.dark, AppColors.dark);

  static ThemeData _build(Brightness b, AppColors c) {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: b).copyWith(
      primary: c.accent,
      onPrimary: c.onAccent,
      primaryContainer: c.accentSoft,
      onPrimaryContainer: c.accentStrong,
      error: c.fail,
      errorContainer: c.failSoft,
      surface: b == Brightness.light ? const Color(0xFFFFFFFF) : const Color(0xFF141B17),
      onSurface: c.fg,
      onSurfaceVariant: c.fg2,
      surfaceContainerLowest: b == Brightness.light ? const Color(0xFFFFFFFF) : const Color(0xFF0D1210),
      surfaceContainerLow: c.surface2,
      surfaceContainer: c.surface2,
      surfaceContainerHigh: c.surface3,
      surfaceContainerHighest: c.surface3,
      outline: c.line,
      outlineVariant: c.line,
    );
    final base = ThemeData(colorScheme: scheme, brightness: b, fontFamily: uiFamily, extensions: [c]);
    const shape12 = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)));
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 20, color: c.fg),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
          side: BorderSide(color: c.line),
        ),
        margin: const EdgeInsets.symmetric(vertical: 6),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: shape12,
          textStyle: const TextStyle(fontFamily: uiFamily, fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: shape12,
          side: BorderSide(color: c.line),
          textStyle: const TextStyle(fontFamily: uiFamily, fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.surface3,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        labelStyle: TextStyle(fontFamily: uiFamily, fontSize: 12, fontWeight: FontWeight.w500, color: c.fg),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surface2,
        indicatorColor: c.accentSoft,
        surfaceTintColor: Colors.transparent,
        height: 72,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontFamily: uiFamily,
            fontSize: 12,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
            color: s.contains(WidgetState.selected) ? c.accentStrong : c.fg2,
          ),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg))),
      ),
      dividerTheme: DividerThemeData(color: c.line, space: 1, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: c.line),
        ),
      ),
      listTileTheme: const ListTileThemeData(minVerticalPadding: 12),
    );
  }
}
