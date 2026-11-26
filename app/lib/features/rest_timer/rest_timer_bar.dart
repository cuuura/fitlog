// B3 소유. 세션 화면 하단에 붙이는 휴식 타이머 막대. 골격은 최소 표시만 한다.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/clock.dart';
import 'rest_timer_controller.dart';

class RestTimerBar extends ConsumerStatefulWidget {
  const RestTimerBar({super.key});
  @override
  ConsumerState<RestTimerBar> createState() => _RestTimerBarState();
}

class _RestTimerBarState extends ConsumerState<RestTimerBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(restTimerProvider);
    if (!s.running) return const SizedBox.shrink();
    final left = s.remaining(ref.read(clockProvider)());
    final mm = left.inMinutes.toString().padLeft(2, '0');
    final ss = (left.inSeconds % 60).toString().padLeft(2, '0');
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: ListTile(
        title: Text('$mm:$ss'),
        trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => ref.read(restTimerProvider.notifier).stop()),
      ),
    );
  }
}
