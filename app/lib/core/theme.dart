import 'package:material_ui/material_ui.dart';

/// 시스템 설정을 따르는 라이트/다크 테마.
abstract final class AppTheme {
  static const _seed = Color(0xFF2E7D5B);
  static ThemeData light() => ThemeData(colorSchemeSeed: _seed, brightness: Brightness.light);
  static ThemeData dark() => ThemeData(colorSchemeSeed: _seed, brightness: Brightness.dark);
}
