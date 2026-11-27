// B3 소유. LOG-4 휴식 타이머.
// 사용(B2): ref.read(restTimerProvider.notifier).start(settings.defaultRestSec, label: '스쿼트 2세트 후');
// - 상태는 endsAt(종료 시각) 기반이라 앱이 잠시 멈춰도 어긋나지 않는다.
// - 시작·연장하면 상단 알림(ongoing + 카운트다운)과 종료 알림 예약을 갱신한다(RestTimerNotifier).
// - 앱이 포그라운드에서 끝나면 진동한다. 백그라운드는 예약된 종료 알림이 소리·진동을 낸다.
// - 앱을 다시 켜면 아직 끝나지 않은 타이머를 shared_preferences에서 복구한다.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/clock.dart';
import 'rest_timer_notifier.dart';

/// 종료 이만큼 전에 사전 경고(진동·알림)를 한다.
const kRestWarnLead = Duration(seconds: 10);

/// 전체 휴식이 이 시간 이하면 사전 경고를 하지 않는다.
const kRestWarnMinTotal = Duration(seconds: 15);

class RestTimerState {
  /// null이면 멈춤.
  final DateTime? endsAt;
  final int totalSec;
  final String? label;

  /// 알림 본문("다음 벤치 프레스 92.5kg×3"). 없으면 기본 문구.
  final String? body;
  const RestTimerState({this.endsAt, this.totalSec = 0, this.label, this.body});

  bool get running => endsAt != null;

  /// 0 이하로 내려가지 않는다.
  Duration remaining(DateTime nowUtc) {
    if (endsAt == null) return Duration.zero;
    final d = endsAt!.difference(nowUtc);
    return d.isNegative ? Duration.zero : d;
  }

  /// 종료 [kRestWarnLead] 안쪽인가(남은 시간이 0보다 크고 10초 이하).
  bool inWarning(DateTime nowUtc) {
    final r = remaining(nowUtc);
    return running && r > Duration.zero && r <= kRestWarnLead;
  }

  /// 0.0(방금 시작) ~ 1.0(끝). totalSec이 0이면 1.
  double progress(DateTime nowUtc) {
    if (totalSec <= 0) return 1;
    final left = remaining(nowUtc).inMilliseconds;
    return (1 - left / (totalSec * 1000)).clamp(0.0, 1.0);
  }
}

/// 재시작 복구용 저장소.
abstract interface class RestTimerStorage {
  Future<RestTimerState?> load();
  Future<void> save(RestTimerState state);
  Future<void> clear();
}

class SharedPrefsRestTimerStorage implements RestTimerStorage {
  static const _kEnds = 'restTimer.endsAt';
  static const _kTotal = 'restTimer.totalSec';
  static const _kLabel = 'restTimer.label';
  static const _kBody = 'restTimer.body';

  @override
  Future<RestTimerState?> load() async {
    final p = await SharedPreferences.getInstance();
    final ends = p.getString(_kEnds);
    if (ends == null) return null;
    return RestTimerState(
      endsAt: DateTime.tryParse(ends)?.toUtc(),
      totalSec: p.getInt(_kTotal) ?? 0,
      label: p.getString(_kLabel),
      body: p.getString(_kBody),
    );
  }

  @override
  Future<void> save(RestTimerState s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kEnds, s.endsAt!.toUtc().toIso8601String());
    await p.setInt(_kTotal, s.totalSec);
    if (s.label == null) {
      await p.remove(_kLabel);
    } else {
      await p.setString(_kLabel, s.label!);
    }
    if (s.body == null) {
      await p.remove(_kBody);
    } else {
      await p.setString(_kBody, s.body!);
    }
  }

  @override
  Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kEnds);
    await p.remove(_kTotal);
    await p.remove(_kLabel);
    await p.remove(_kBody);
  }
}

final restTimerStorageProvider = Provider<RestTimerStorage>((ref) => SharedPrefsRestTimerStorage());

/// 포그라운드에서 타이머가 끝났을 때의 진동. 테스트는 override한다.
final restTimerVibrateProvider = Provider<Future<void> Function()>((ref) => () async {
      for (var i = 0; i < 3; i++) {
        await HapticFeedback.vibrate();
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    });

/// 종료 10초 전 사전 경고 진동(짧게 한 번). 테스트는 override한다.
final restTimerWarnVibrateProvider = Provider<Future<void> Function()>((ref) => () async {
      await HapticFeedback.heavyImpact();
    });

class RestTimerController extends Notifier<RestTimerState> {
  Timer? _finishTimer;
  Timer? _warnTimer;
  DateTime? _warnedFor;
  bool _permissionAsked = false;

  /// 끝난 시각에서 이 시간이 넘게 지나 있으면(앱이 멈춰 있다 돌아온 경우) 진동하지 않는다.
  static const _vibrateWindow = Duration(seconds: 3);

  @override
  RestTimerState build() {
    final notifier = ref.read(restTimerNotifierProvider);
    notifier.actionHandler = _onAction;
    ref.onDispose(() {
      _finishTimer?.cancel();
      _warnTimer?.cancel();
      notifier.actionHandler = null;
    });
    // 이미 start()가 불렸다면 복구하지 않는다(_restore에서 확인).
    scheduleMicrotask(_restore);
    return const RestTimerState();
  }

  DateTime _now() => ref.read(clockProvider)();

  void _onAction(RestTimerAction a) {
    switch (a) {
      case RestTimerAction.add30:
        addSeconds(30);
      case RestTimerAction.skip:
        stop();
    }
  }

  void start(int seconds, {String? label, String? body}) {
    if (seconds <= 0) {
      stop();
      return;
    }
    state = RestTimerState(endsAt: _now().add(Duration(seconds: seconds)), totalSec: seconds, label: label, body: body);
    _arm(askPermission: true);
  }

  /// 음수면 줄인다(남은 시간이 0 이하가 되면 멈춘다). 멈춘 상태면 무시.
  void addSeconds(int seconds) {
    final e = state.endsAt;
    if (e == null) return;
    final next = e.add(Duration(seconds: seconds));
    if (!next.isAfter(_now())) {
      stop();
      return;
    }
    state = RestTimerState(endsAt: next, totalSec: state.totalSec + seconds, label: state.label, body: state.body);
    _arm();
  }

  void stop() {
    _finishTimer?.cancel();
    _warnTimer?.cancel();
    _warnedFor = null;
    state = const RestTimerState();
    _guard(() => ref.read(restTimerNotifierProvider).cancel());
    _guard(() => ref.read(restTimerStorageProvider).clear());
  }

  /// 종료 시각이 지났는지 확인한다. 지났으면 진동하고 멈춘다(내부 Timer가 부르며, 테스트에서도 직접 부른다).
  void checkFinished() {
    final e = state.endsAt;
    if (e == null) return;
    final now = _now();
    if (e.isAfter(now)) {
      _finishTimer?.cancel();
      _finishTimer = Timer(e.difference(now), checkFinished);
      return;
    }
    final fresh = now.difference(e) <= _vibrateWindow;
    _finishTimer?.cancel();
    _warnTimer?.cancel();
    state = const RestTimerState();
    _guard(() => ref.read(restTimerStorageProvider).clear());
    // 예약된 종료 알림(소리·진동)은 그대로 둔다. 진행 중 알림은 timeoutAfter로 사라진다.
    if (fresh) _guard(() => ref.read(restTimerVibrateProvider)());
  }

  /// 종료 10초 전이 되면 한 번만 짧게 진동한다(내부 Timer가 부르며, 테스트에서도 직접 부른다).
  void checkWarning() {
    final e = state.endsAt;
    if (e == null || state.totalSec <= kRestWarnMinTotal.inSeconds) return;
    final now = _now();
    final at = e.subtract(kRestWarnLead);
    if (at.isAfter(now)) {
      _warnTimer?.cancel();
      _warnTimer = Timer(at.difference(now), checkWarning);
      return;
    }
    if (_warnedFor == e || !e.isAfter(now)) return;
    _warnedFor = e;
    _guard(() => ref.read(restTimerWarnVibrateProvider)());
  }

  void _arm({bool askPermission = false}) {
    final s = state;
    _finishTimer?.cancel();
    _finishTimer = Timer(s.endsAt!.difference(_now()), checkFinished);
    _warnTimer?.cancel();
    final warnAt = s.endsAt!.subtract(kRestWarnLead);
    final warn = s.totalSec > kRestWarnMinTotal.inSeconds;
    if (warn && warnAt.isAfter(_now())) {
      _warnTimer = Timer(warnAt.difference(_now()), checkWarning);
    }
    final notifier = ref.read(restTimerNotifierProvider);
    if (warn && warnAt.isAfter(_now())) {
      _guard(() => notifier.scheduleWarning(at: warnAt, body: s.body));
    } else {
      _guard(() => notifier.cancelWarning());
    }
    _guard(() async {
      if (askPermission && !_permissionAsked) {
        _permissionAsked = true;
        await notifier.requestPermission();
      }
      await notifier.showRunning(endsAt: s.endsAt!, totalSec: s.totalSec, label: s.label, body: s.body, now: _now());
    });
    _guard(() => ref.read(restTimerStorageProvider).save(s));
  }

  Future<void> _restore() async {
    if (state.running) return;
    try {
      final saved = await ref.read(restTimerStorageProvider).load();
      if (saved == null || state.running) return;
      if (saved.endsAt == null || !saved.endsAt!.isAfter(_now())) {
        await ref.read(restTimerStorageProvider).clear();
        return;
      }
      state = saved;
      _arm();
    } catch (_) {
      // 복구는 선택 기능이다.
    }
  }

  /// 알림·저장소 오류가 타이머 자체를 깨뜨리지 않게 한다.
  void _guard(Future<void> Function() f) {
    unawaited(Future.sync(f).catchError((Object _) {}));
  }
}

final restTimerProvider = NotifierProvider<RestTimerController, RestTimerState>(RestTimerController.new);
