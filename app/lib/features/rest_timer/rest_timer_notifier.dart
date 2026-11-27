// B3 소유. 휴식 타이머의 시스템 알림(LOG-12 일부).
// - 타이머가 도는 동안: ongoing 알림(카운트다운 크로노미터, 잠금화면에도 표시, +30초/건너뛰기 액션)
// - 끝나는 시각: 소리·진동 알림을 예약(앱이 백그라운드여도 울림). 정확한 알람 권한이 없으면 inexact로 폴백
// 컨트롤러는 인터페이스([RestTimerNotifier])만 알고, 테스트는 가짜를 끼운다.
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../l10n/gen/app_localizations.dart';

enum RestTimerAction { add30, skip }

abstract interface class RestTimerNotifier {
  /// 알림 권한(Android 13+ POST_NOTIFICATIONS)을 요청한다. 이미 허용·거부 상태면 조용히 끝난다.
  Future<void> requestPermission();

  /// 진행 중 알림을 띄우거나 갱신하고, 종료 알림을 [endsAt]에 예약한다(이미 있으면 교체).
  Future<void> showRunning({required DateTime endsAt, required int totalSec, String? label, String? body, required DateTime now});

  /// 종료 [at] 시각에 "휴식 10초 남음" 사전 경고 알림을 예약한다(이미 있으면 교체).
  Future<void> scheduleWarning({required DateTime at, String? body});

  /// 예약된 사전 경고만 지운다.
  Future<void> cancelWarning();

  /// 정확한 알람 권한 요청을 지원하는 플랫폼인가(Android만). 아니면 설정 항목을 숨긴다.
  bool get supportsExactAlarm;

  /// 정확한 알람 권한(SCHEDULE_EXACT_ALARM)을 요청한다. 요청을 했으면 true, 지원 안 하면 false.
  Future<bool> requestExactAlarmPermission();

  /// 진행 중 알림과 예약된 종료 알림을 모두 지운다.
  Future<void> cancel();

  /// 알림 액션(+30초, 건너뛰기)이 눌렸을 때 부를 핸들러.
  set actionHandler(void Function(RestTimerAction action)? handler);
}

/// flutter_local_notifications 구현. Android 전용(다른 플랫폼에서는 아무것도 하지 않는다).
class LocalRestTimerNotifier implements RestTimerNotifier {
  static const _runningId = 7001;
  static const _doneId = 7002;
  static const _warnId = 7003;
  static const _actionAdd30 = 'rest_add30';
  static const _actionSkip = 'rest_skip';

  final FlutterLocalNotificationsPlugin _plugin;
  void Function(RestTimerAction)? _handler;
  Future<void>? _initFuture;

  LocalRestTimerNotifier({FlutterLocalNotificationsPlugin? plugin}) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  set actionHandler(void Function(RestTimerAction)? handler) => _handler = handler;

  AppLocalizations get _l10n {
    final Locale locale = PlatformDispatcher.instance.locale;
    try {
      return lookupAppLocalizations(locale);
    } catch (_) {
      return lookupAppLocalizations(const Locale('ko'));
    }
  }

  Future<void> _init() => _initFuture ??= _plugin
      .initialize(
        settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (r) {
          switch (r.actionId) {
            case _actionAdd30:
              _handler?.call(RestTimerAction.add30);
            case _actionSkip:
              _handler?.call(RestTimerAction.skip);
          }
        },
      )
      .then((_) {});

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  @override
  Future<void> requestPermission() async {
    if (!_supported) return;
    await _init();
    await _android?.requestNotificationsPermission();
  }

  @override
  Future<void> showRunning({required DateTime endsAt, required int totalSec, String? label, String? body, required DateTime now}) async {
    if (!_supported) return;
    await _init();
    final l = _l10n;
    final remainingMs = endsAt.difference(now).inMilliseconds;
    if (remainingMs <= 0) return;
    final title = label == null || label.isEmpty ? l.timerRestTitle : l.timerRestTitleWithLabel(label);

    await _plugin.show(
      id: _runningId,
      title: title,
      body: body == null || body.isEmpty ? l.timerRunningBody : body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'rest_timer_running',
          l.timerChannelRunning,
          channelDescription: l.timerChannelRunningDesc,
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          playSound: false,
          enableVibration: false,
          showWhen: true,
          when: endsAt.millisecondsSinceEpoch,
          usesChronometer: true,
          chronometerCountDown: true,
          visibility: NotificationVisibility.public,
          timeoutAfter: remainingMs,
          actions: [
            AndroidNotificationAction(_actionAdd30, l.timerAddSeconds(30), showsUserInterface: true),
            AndroidNotificationAction(_actionSkip, l.timerSkip, showsUserInterface: true),
          ],
        ),
      ),
    );

    await _plugin.zonedSchedule(
      id: _doneId,
      title: l.timerDoneTitle,
      body: l.timerDoneBody,
      scheduledDate: tz.TZDateTime.from(endsAt, tz.UTC),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'rest_timer_done',
          l.timerChannelDone,
          channelDescription: l.timerChannelDoneDesc,
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 400, 200, 400, 200, 400]),
          visibility: NotificationVisibility.public,
        ),
      ),
      androidScheduleMode: await _scheduleMode(),
    );
  }

  @override
  Future<void> scheduleWarning({required DateTime at, String? body}) async {
    if (!_supported) return;
    await _init();
    final l = _l10n;
    await _plugin.zonedSchedule(
      id: _warnId,
      title: l.sessionCurWarnTitle,
      body: body == null || body.isEmpty ? l.sessionCurWarnBody : body,
      scheduledDate: tz.TZDateTime.from(at, tz.UTC),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'rest_timer_warn',
          l.sessionCurChannelWarn,
          channelDescription: l.sessionCurChannelWarnDesc,
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 200, 100, 200]),
          timeoutAfter: 10000,
          visibility: NotificationVisibility.public,
        ),
      ),
      androidScheduleMode: await _scheduleMode(),
    );
  }

  @override
  Future<void> cancelWarning() async {
    if (!_supported) return;
    await _init();
    await _plugin.cancel(id: _warnId);
  }

  /// 정확한 알람 권한(SCHEDULE_EXACT_ALARM)이 있으면 exact, 없으면 inexact. 사용자를 설정 화면으로 보내지 않는다.
  Future<AndroidScheduleMode> _scheduleMode() async {
    final canExact = await _android?.canScheduleExactNotifications() ?? false;
    return canExact ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle;
  }

  @override
  bool get supportsExactAlarm => _supported;

  /// 설정 화면의 "정확한 알림" 항목에서 부른다.
  @override
  Future<bool> requestExactAlarmPermission() async {
    if (!_supported) return false;
    await _init();
    await _android?.requestExactAlarmsPermission();
    return true;
  }

  @override
  Future<void> cancel() async {
    if (!_supported) return;
    await _init();
    await _plugin.cancel(id: _runningId);
    await _plugin.cancel(id: _doneId);
    await _plugin.cancel(id: _warnId);
  }
}

/// 아무것도 하지 않는 구현(웹·테스트 기본값 대용).
class NoopRestTimerNotifier implements RestTimerNotifier {
  @override
  set actionHandler(void Function(RestTimerAction)? handler) {}
  @override
  bool get supportsExactAlarm => false;
  @override
  Future<bool> requestExactAlarmPermission() async => false;
  @override
  Future<void> cancel() async {}
  @override
  Future<void> scheduleWarning({required DateTime at, String? body}) async {}
  @override
  Future<void> cancelWarning() async {}
  @override
  Future<void> requestPermission() async {}
  @override
  Future<void> showRunning({required DateTime endsAt, required int totalSec, String? label, String? body, required DateTime now}) async {}
}

final restTimerNotifierProvider = Provider<RestTimerNotifier>((ref) => LocalRestTimerNotifier());
