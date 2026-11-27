// C 담당. 그래프 비교(목업 6번)의 차트 두 개. fl_chart의 막대에는 사선 빗금이 없어 CustomPainter로 직접 그린다.
// 구분은 색만이 아니라 모양으로도: 오늘=채움, 지난번=사선 빗금, PR=점선+별.
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';

/// 별 모양 경로(꼭짓점 5개). [r]은 바깥 반지름.
Path starPath(Offset c, double r) {
  final p = Path();
  for (var i = 0; i < 10; i++) {
    final rad = i.isEven ? r : r * 0.45;
    final a = -math.pi / 2 + i * math.pi / 5;
    final o = Offset(c.dx + rad * math.cos(a), c.dy + rad * math.sin(a));
    i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
  }
  return p..close();
}

/// 가로 점선.
void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint, {double on = 6, double off = 4}) {
  final len = (b - a).distance;
  final dir = (b - a) / len;
  var d = 0.0;
  while (d < len) {
    final e = math.min(d + on, len);
    canvas.drawLine(a + dir * d, a + dir * e, paint);
    d += on + off;
  }
}

/// 사선 빗금 채움 + 테두리 막대(지난번). 범례 견본에도 쓴다.
void paintHatchedRect(Canvas canvas, RRect rect, Color color) {
  canvas.save();
  canvas.clipRRect(rect);
  final line = Paint()
    ..color = color
    ..strokeWidth = 1.5;
  final r = rect.outerRect;
  for (var x = r.left - r.height; x < r.right; x += 5) {
    canvas.drawLine(Offset(x, r.bottom), Offset(x + r.height, r.top), line);
  }
  canvas.restore();
  canvas.drawRRect(
    rect.deflate(0.75),
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5,
  );
}

TextPainter _text(String s, TextStyle style, {TextAlign align = TextAlign.left}) =>
    TextPainter(text: TextSpan(text: s, style: style), textAlign: align, textDirection: TextDirection.ltr)..layout();

/// 범례 견본 하나. [kind]: today(채움) / last(사선) / pr(점선) / line(꺾은선) / ring(가장 최근) / star(PR 별).
enum LegendKind { today, last, pr, line, ring, star }

class LegendSwatch extends StatelessWidget {
  const LegendSwatch(this.kind, {super.key});
  final LegendKind kind;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ExcludeSemantics(
      child: CustomPaint(
        size: const Size(16, 14),
        painter: _SwatchPainter(kind, c),
      ),
    );
  }
}

class _SwatchPainter extends CustomPainter {
  _SwatchPainter(this.kind, this.c);
  final LegendKind kind;
  final AppColors c;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = Offset(size.width / 2, size.height / 2);
    switch (kind) {
      case LegendKind.today:
        canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(2)), Paint()..color = c.accent);
      case LegendKind.last:
        paintHatchedRect(canvas, RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(2)), c.last);
      case LegendKind.pr:
        _dashedLine(
          canvas,
          Offset(0, mid.dy),
          Offset(size.width, mid.dy),
          Paint()
            ..color = c.pr
            ..strokeWidth = 2.5,
          on: 5,
          off: 3,
        );
      case LegendKind.line:
        canvas.drawPath(
          Path()
            ..moveTo(0, 11)
            ..lineTo(6, 6)
            ..lineTo(10, 9)
            ..lineTo(16, 2),
          Paint()
            ..color = c.accentStrong
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
      case LegendKind.ring:
        canvas.drawCircle(
          mid,
          5,
          Paint()
            ..color = c.accentStrong
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      case LegendKind.star:
        canvas.drawPath(starPath(mid, 7), Paint()..color = c.pr);
    }
  }

  @override
  bool shouldRepaint(_SwatchPainter old) => old.kind != kind || old.c != c;
}

/// 세트 번호별 횟수 막대. 오늘(채움)·지난번(사선)·이전 PR 횟수(점선+별).
class RepsBarChart extends StatelessWidget {
  const RepsBarChart({
    super.key,
    required this.today,
    required this.last,
    this.prReps,
    required this.setLabel,
    required this.prLabel,
    required this.axisLabel,
    required this.semantics,
  });

  /// 세트 순서대로의 횟수. 해당 세트가 없으면 null.
  final List<int?> today;
  final List<int?> last;
  final int? prReps;
  final String Function(int number) setLabel;
  final String prLabel;
  final String axisLabel;
  final String semantics;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      label: semantics,
      image: true,
      child: ExcludeSemantics(
        child: AspectRatio(
          aspectRatio: 316 / 206,
          child: CustomPaint(
            painter: _RepsBarPainter(
              today: today,
              last: last,
              prReps: prReps,
              setLabel: setLabel,
              prLabel: prLabel,
              axisLabel: axisLabel,
              colors: c,
              base: TextStyle(fontFamily: AppTheme.uiFamily, fontSize: 11, color: c.fg2),
              numStyle: AppNum.style(context, 13, weight: FontWeight.w600),
            ),
          ),
        ),
      ),
    );
  }
}

class _RepsBarPainter extends CustomPainter {
  _RepsBarPainter({
    required this.today,
    required this.last,
    required this.prReps,
    required this.setLabel,
    required this.prLabel,
    required this.axisLabel,
    required this.colors,
    required this.base,
    required this.numStyle,
  });
  final List<int?> today, last;
  final int? prReps;
  final String Function(int) setLabel;
  final String prLabel, axisLabel;
  final AppColors colors;
  final TextStyle base, numStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final n = math.max(today.length, last.length);
    if (n == 0) return;
    final maxV = [...today, ...last, prReps].whereType<int>().fold<int>(1, math.max);
    final top = ((maxV + 1) ~/ 2) * 2 + (maxV.isOdd ? 0 : 2); // 짝수 눈금, 최댓값 위에 여백
    const left = 28.0, topPad = 24.0, bottomPad = 36.0;
    final right = size.width - 48;
    final plotH = size.height - topPad - bottomPad;
    final y0 = topPad + plotH;
    double yOf(num v) => y0 - v / top * plotH;

    final gridPaint = Paint()
      ..color = colors.line
      ..strokeWidth = 1;
    final axisTitle = _text(axisLabel, base);
    axisTitle.paint(canvas, const Offset(0, 0));
    for (var v = 0; v <= top; v += 2) {
      canvas.drawLine(
        Offset(left, yOf(v)),
        Offset(right, yOf(v)),
        v == 0
            ? (Paint()
                ..color = colors.fg2
                ..strokeWidth = 1)
            : gridPaint,
      );
      final t = _text('$v', base);
      t.paint(canvas, Offset(left - 6 - t.width, yOf(v) - t.height / 2));
    }

    final slot = (right - left) / n;
    final barW = math.min(18.0, (slot - 10) / 2);
    for (var i = 0; i < n; i++) {
      final cx = left + slot * (i + 0.5);
      void bar(int? v, double x, bool isToday) {
        if (v == null) return;
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTRB(x, yOf(v), x + barW, y0),
          const Radius.circular(2),
        );
        if (isToday) {
          canvas.drawRRect(rect, Paint()..color = colors.accent);
        } else {
          paintHatchedRect(canvas, rect, colors.last);
        }
        final t = _text('$v', numStyle.copyWith(color: isToday ? colors.fg : colors.fg2), align: TextAlign.center);
        t.paint(canvas, Offset(x + barW / 2 - t.width / 2, yOf(v) - t.height - 2));
      }

      bar(i < today.length ? today[i] : null, cx - barW - 1.5, true);
      bar(i < last.length ? last[i] : null, cx + 1.5, false);
      final lab = _text(setLabel(i + 1), base);
      lab.paint(canvas, Offset(cx - lab.width / 2, y0 + 8));
    }

    if (prReps != null) {
      final y = yOf(prReps!);
      _dashedLine(
        canvas,
        Offset(left, y),
        Offset(right + 4, y),
        Paint()
          ..color = colors.pr
          ..strokeWidth = 2.5,
      );
      canvas.drawPath(starPath(Offset(right + 14, y), 6), Paint()..color = colors.pr);
      final t = _text(prLabel, base.copyWith(color: colors.pr, fontWeight: FontWeight.w700));
      t.paint(canvas, Offset(right + 22, y - t.height / 2));
    }
  }

  @override
  bool shouldRepaint(_RepsBarPainter old) =>
      old.today != today || old.last != last || old.prReps != prReps || old.colors != colors;
}

/// 추정 1RM 꺾은선: PR 점은 호박색 별, 가장 최근은 큰 고리, 최근 값 라벨.
class TrendPoint {
  const TrendPoint(this.value, this.label, this.isPr);
  final double value;
  final String label;
  final bool isPr;
}

class E1rmTrendChart extends StatelessWidget {
  const E1rmTrendChart({
    super.key,
    required this.points,
    required this.valueLabel,
    required this.unitLabel,
    required this.semantics,
  });

  final List<TrendPoint> points;

  /// 값을 표시 문자열로(소수 자리·단위 변환은 호출자가).
  final String Function(double value) valueLabel;
  final String unitLabel;
  final String semantics;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      label: semantics,
      image: true,
      child: ExcludeSemantics(
        child: AspectRatio(
          aspectRatio: 316 / 206,
          child: CustomPaint(
            painter: _TrendPainter(
              points: points,
              valueLabel: valueLabel,
              unitLabel: unitLabel,
              colors: c,
              surface: Theme.of(context).colorScheme.surface,
              base: TextStyle(fontFamily: AppTheme.uiFamily, fontSize: 11, color: c.fg2),
              numStyle: AppNum.style(context, 14, weight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.points,
    required this.valueLabel,
    required this.unitLabel,
    required this.colors,
    required this.surface,
    required this.base,
    required this.numStyle,
  });
  final List<TrendPoint> points;
  final String Function(double) valueLabel;
  final String unitLabel;
  final AppColors colors;
  final Color surface;
  final TextStyle base, numStyle;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final vals = points.map((p) => p.value);
    var lo = vals.reduce(math.min), hi = vals.reduce(math.max);
    final step = _niceStep(hi - lo);
    lo = (lo / step).floor() * step;
    hi = (hi / step).ceil() * step;
    if (hi == lo) hi = lo + step;
    const left = 36.0, topPad = 28.0, bottomPad = 30.0;
    final right = size.width - 16;
    final plotH = size.height - topPad - bottomPad;
    double yOf(double v) => topPad + plotH - (v - lo) / (hi - lo) * plotH;
    final n = points.length;
    double xOf(int i) => n == 1 ? (left + right) / 2 : left + (right - left) * i / (n - 1);

    final grid = Paint()
      ..color = colors.line
      ..strokeWidth = 1;
    _text(unitLabel, base).paint(canvas, Offset.zero);
    for (var v = lo; v <= hi + 0.0001; v += step) {
      canvas.drawLine(Offset(left, yOf(v)), Offset(right, yOf(v)), grid);
      final t = _text(valueLabel(v), base);
      t.paint(canvas, Offset(left - 6 - t.width, yOf(v) - t.height / 2));
    }

    final path = Path();
    for (var i = 0; i < n; i++) {
      final o = Offset(xOf(i), yOf(points[i].value));
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = colors.accentStrong
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    for (var i = 0; i < n; i++) {
      final o = Offset(xOf(i), yOf(points[i].value));
      if (points[i].isPr) {
        // 별은 점 위에 얹어 PR을 색 말고 모양으로도 알린다.
        final star = starPath(o.translate(0, -9), 8);
        canvas.drawPath(star, Paint()..color = colors.pr);
        canvas.drawPath(
          star,
          Paint()
            ..color = surface
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..strokeJoin = StrokeJoin.round,
        );
      } else {
        canvas.drawCircle(o, 3.5, Paint()..color = surface);
        canvas.drawCircle(
          o,
          3.5,
          Paint()
            ..color = colors.accentStrong
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
    final lastO = Offset(xOf(n - 1), yOf(points.last.value));
    canvas.drawCircle(
      lastO,
      12,
      Paint()
        ..color = colors.accentStrong
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final vt = _text(valueLabel(points.last.value), numStyle.copyWith(color: colors.fg));
    vt.paint(canvas, Offset(math.min(lastO.dx + 8, size.width) - vt.width, math.max(0, lastO.dy - 12 - vt.height - 10)));

    // x축 라벨: 처음·가운데·마지막.
    void xl(int i, TextAlign a) {
      final t = _text(points[i].label, base);
      final x = xOf(i);
      final dx = switch (a) {
        TextAlign.left => x,
        TextAlign.right => x - t.width,
        _ => x - t.width / 2,
      };
      t.paint(canvas, Offset(dx, size.height - 16));
    }

    xl(0, TextAlign.left);
    if (n >= 5) xl(n ~/ 2, TextAlign.center);
    if (n > 1) xl(n - 1, TextAlign.right);
  }

  static double _niceStep(double range) {
    if (range <= 0) return 1;
    final raw = range / 4;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    for (final m in [1, 2, 2.5, 5, 10]) {
      if (raw <= m * mag) return m * mag;
    }
    return 10 * mag;
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.points != points || old.colors != colors || old.surface != surface;
}
