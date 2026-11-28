// B3(v1.2) 운동 알림 예약 구현(flutter_local_notifications). 서비스는 인터페이스만 안다.
// 휴식 타이머와 같은 플러그인·권한 처리 방식을 쓰되 채널 id('workout_reminder')와 알림 id 범위(7100~)는 따로 쓴다.
// 알림을 누르면 앱이 열린다(콜드 스타트는 홈에서 시작). 플러그인 initialize는 휴식 타이머가 소유한 응답 콜백을 덮지 않으려고 여기서 하지 않는다.
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../features/rest_timer/rest_timer_notifier.dart';
import '../../l10n/gen/app_localizations.dart';
import 'reminder_logic.dart';

abstract interface class ReminderScheduler {
  /// 알림 권한(Android 13+)을 요청한다. 휴식 타이머의 권한 처리와 같다.
  Future<void> requestPermission();

  /// 이전에 예약한 운동 알림을 모두 지운다.
  Future<void> cancelAll();

  /// [entries]를 예약한다. 호출 쪽이 먼저 [cancelAll]을 부른다.
  Future<void> schedule(List<ReminderEntry> entries);
}

class LocalReminderScheduler implements ReminderScheduler {
  LocalReminderScheduler({FlutterLocalNotificationsPlugin? plugin, this._permissions})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const channelId = 'workout_reminder';
  static const payload = 'reminder';

  final FlutterLocalNotificationsPlugin _plugin;
  final RestTimerNotifier? _permissions;

  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  AppLocalizations get _l10n {
    final Locale locale = PlatformDispatcher.instance.locale;
    try {
      return lookupAppLocalizations(locale);
    } catch (_) {
      return lookupAppLocalizations(const Locale('ko'));
    }
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  @override
  Future<void> requestPermission() async {
    if (!_supported) return;
    await _permissions?.requestPermission();
  }

  @override
  Future<void> cancelAll() async {
    if (!_supported) return;
    for (var i = 0; i < reminderIdCount; i++) {
      await _plugin.cancel(id: reminderIdBase + i);
    }
  }

  @override
  Future<void> schedule(List<ReminderEntry> entries) async {
    if (!_supported || entries.isEmpty) return;
    final l = _l10n;
    final canExact = await _android?.canScheduleExactNotifications() ?? false;
    final mode = canExact ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle;
    for (final e in entries) {
      await _plugin.zonedSchedule(
        id: e.id,
        title: e.tomorrow ? l.reminderTitleTomorrow : l.reminderTitleToday,
        body: l.reminderBody,
        scheduledDate: tz.TZDateTime.from(e.at, tz.UTC),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            l.reminderChannel,
            channelDescription: l.reminderChannelDesc,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            icon: '@mipmap/ic_launcher',
            visibility: NotificationVisibility.public,
          ),
        ),
        androidScheduleMode: mode,
        payload: payload,
      );
    }
  }
}

final reminderSchedulerProvider = Provider<ReminderScheduler>(
  (ref) => LocalReminderScheduler(permissions: ref.watch(restTimerNotifierProvider)),
);
