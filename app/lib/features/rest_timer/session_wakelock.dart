// B3 소유. 세션 화면을 감싸면 설정(keepScreenOn)에 따라, 이 위젯이 화면에 있는 동안 화면 꺼짐을 막는다.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/settings/settings_controller.dart';

/// wakelock 켜기/끄기. 테스트는 override해서 호출을 기록한다.
final wakelockToggleProvider = Provider<Future<void> Function(bool enable)>(
  (ref) => (enable) => WakelockPlus.toggle(enable: enable),
);

class SessionWakelock extends ConsumerStatefulWidget {
  final Widget child;
  const SessionWakelock({super.key, required this.child});

  @override
  ConsumerState<SessionWakelock> createState() => _SessionWakelockState();
}

class _SessionWakelockState extends ConsumerState<SessionWakelock> {
  late final Future<void> Function(bool) _toggle;
  bool? _applied;

  @override
  void initState() {
    super.initState();
    _toggle = ref.read(wakelockToggleProvider);
    _apply(ref.read(settingsProvider).keepScreenOn);
  }

  void _apply(bool enable) {
    if (_applied == enable) return;
    _applied = enable;
    // 플랫폼 채널이 없는 환경(테스트, 일부 플랫폼)에서도 앱이 죽지 않게 한다.
    _toggle(enable).catchError((Object _) {});
  }

  @override
  void dispose() {
    if (_applied == true) _toggle(false).catchError((Object _) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _apply(ref.watch(settingsProvider.select((s) => s.keepScreenOn)));
    return widget.child;
  }
}
