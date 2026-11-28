// B3(v1.2) 운동 알림(LOG-12) 설정. 기기에만 저장한다(shared_preferences, 서버 설정과 무관).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reminder_service.dart';

/// 알림 날: 당일 지정 시각, 또는 전날 저녁 20:00.
enum ReminderWhen { sameDay, eveBefore }

class ReminderSettings {
  final bool enabled;
  final int hour;
  final int minute;
  final ReminderWhen when;
  const ReminderSettings({this.enabled = false, this.hour = 8, this.minute = 0, this.when = ReminderWhen.sameDay});

  ReminderSettings copyWith({bool? enabled, int? hour, int? minute, ReminderWhen? when}) => ReminderSettings(
    enabled: enabled ?? this.enabled,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    when: when ?? this.when,
  );

  @override
  bool operator ==(Object other) =>
      other is ReminderSettings &&
      other.enabled == enabled &&
      other.hour == hour &&
      other.minute == minute &&
      other.when == when;

  @override
  int get hashCode => Object.hash(enabled, hour, minute, when);
}

class ReminderSettingsStore {
  static const keyEnabled = 'reminder.enabled';
  static const keyHour = 'reminder.hour';
  static const keyMinute = 'reminder.minute';
  static const keyWhen = 'reminder.when';

  Future<ReminderSettings> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final h = p.getInt(keyHour) ?? 8;
      final m = p.getInt(keyMinute) ?? 0;
      return ReminderSettings(
        enabled: p.getBool(keyEnabled) ?? false,
        hour: h.clamp(0, 23),
        minute: m.clamp(0, 59),
        when: ReminderWhen.values.asNameMap()[p.getString(keyWhen)] ?? ReminderWhen.sameDay,
      );
    } catch (_) {
      return const ReminderSettings();
    }
  }

  Future<void> save(ReminderSettings s) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(keyEnabled, s.enabled);
    await p.setInt(keyHour, s.hour);
    await p.setInt(keyMinute, s.minute);
    await p.setString(keyWhen, s.when.name);
  }
}

final reminderSettingsStoreProvider = Provider<ReminderSettingsStore>((ref) => ReminderSettingsStore());

/// 화면용 상태. 시작하면 저장값을 읽어 오고, 바꾸면 저장한 뒤 알림을 다시 예약한다.
class ReminderSettingsController extends Notifier<ReminderSettings> {
  int _rev = 0;

  @override
  ReminderSettings build() {
    Future.microtask(_load);
    return const ReminderSettings();
  }

  Future<void> _load() async {
    final rev = _rev;
    final s = await ref.read(reminderSettingsStoreProvider).load();
    if (!ref.mounted || rev != _rev) return;
    state = s;
  }

  /// 저장하고 다시 예약한다. 저장이 실패하면 이전 값으로 되돌리고 예외를 던진다.
  Future<void> update(ReminderSettings next) async {
    final prev = state;
    _rev++;
    state = next;
    try {
      await ref.read(reminderSettingsStoreProvider).save(next);
    } catch (_) {
      state = prev;
      rethrow;
    }
    await ref.read(reminderServiceProvider).reschedule();
  }
}

final reminderSettingsProvider = NotifierProvider<ReminderSettingsController, ReminderSettings>(
  ReminderSettingsController.new,
);
