import 'api/dto.dart';

/// 저장·전송은 항상 kg(소수 둘째 자리). lb는 표시에서만 변환한다 (conventions.md).
abstract final class Units {
  static const kgPerLb = 0.45359237;

  static double roundKg(double kg) => (kg * 100).roundToDouble() / 100;

  /// kg 값을 사용자 단위 숫자로.
  static double toDisplay(double kg, WeightUnit unit) => unit == WeightUnit.KG ? kg : kg / kgPerLb;

  /// 사용자가 입력한 숫자를 저장용 kg로.
  static double fromDisplay(double value, WeightUnit unit) => roundKg(unit == WeightUnit.KG ? value : value * kgPerLb);

  /// 예: 62.5 kg, 137.8 lb. 불필요한 0은 뺀다.
  static String format(double kg, WeightUnit unit, {bool withUnit = true}) {
    final v = toDisplay(kg, unit);
    final s = unit == WeightUnit.KG ? _trim(v.toStringAsFixed(2)) : _trim(v.toStringAsFixed(1));
    return withUnit ? '$s ${unit == WeightUnit.KG ? 'kg' : 'lb'}' : s;
  }

  static String _trim(String s) => s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}
