// B3 소유. LOG-4 휴식 타이머. 골격은 알림 없는 최소 구현이다.
// 사용(B2): ref.read(restTimerProvider.notifier).start(settings.defaultRestSec, label: '스쿼트 2세트 후');
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/clock.dart';

class RestTimerState {
  /// null이면 멈춤.
  final DateTime? endsAt;
  final int totalSec;
  final String? label;
  const RestTimerState({this.endsAt, this.totalSec = 0, this.label});

  bool get running => endsAt != null;

  /// 0 이하로 내려가지 않는다.
  Duration remaining(DateTime nowUtc) {
    if (endsAt == null) return Duration.zero;
    final d = endsAt!.difference(nowUtc);
    return d.isNegative ? Duration.zero : d;
  }
}

class RestTimerController extends Notifier<RestTimerState> {
  @override
  RestTimerState build() => const RestTimerState();

  DateTime _now() => ref.read(clockProvider)();

  void start(int seconds, {String? label}) =>
      state = RestTimerState(endsAt: _now().add(Duration(seconds: seconds)), totalSec: seconds, label: label);

  /// 음수면 줄인다. 멈춘 상태면 무시.
  void addSeconds(int seconds) {
    final e = state.endsAt;
    if (e == null) return;
    state = RestTimerState(endsAt: e.add(Duration(seconds: seconds)), totalSec: state.totalSec + seconds, label: state.label);
  }

  void stop() => state = const RestTimerState();
}

final restTimerProvider = NotifierProvider<RestTimerController, RestTimerState>(RestTimerController.new);
