// B3 소유. 세션 화면 하단에 붙이는 휴식 타이머 막대: 남은 시간 큰 글씨, 진행 막대, -15/+15초, 건너뛰기.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/clock.dart';
import '../../l10n/gen/app_localizations.dart';
import 'rest_timer_controller.dart';

String formatRestRemaining(Duration d) {
  // 올림해서 "00:00"이 남은 시간 0.4초 동안 보이지 않게 한다.
  final secs = (d.inMilliseconds / 1000).ceil();
  final mm = (secs ~/ 60).toString().padLeft(2, '0');
  final ss = (secs % 60).toString().padLeft(2, '0');
  return '$mm:$ss';
}

class RestTimerBar extends ConsumerStatefulWidget {
  const RestTimerBar({super.key, this.nextText});

  /// 휴식 중에 보여줄 "다음 세트" 안내(없으면 생략).
  final String? nextText;
  @override
  ConsumerState<RestTimerBar> createState() => _RestTimerBarState();
}

class _RestTimerBarState extends ConsumerState<RestTimerBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && ref.read(restTimerProvider).running) setState(() {});
    });
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
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final now = ref.read(clockProvider)();
    final left = s.remaining(now);
    final ctrl = ref.read(restTimerProvider.notifier);

    final large = MediaQuery.textScalerOf(context).scale(10) > 13;
    final time = Text(
      formatRestRemaining(left),
      key: const Key('restTimerRemaining'),
      style: Theme.of(context).textTheme.displaySmall?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
        color: scheme.onSecondaryContainer,
      ),
    );
    final buttons = <Widget>[
      TextButton(
        key: const Key('restTimerMinus'),
        onPressed: () => ctrl.addSeconds(-15),
        child: Text(l10n.timerSubSeconds(15)),
      ),
      TextButton(
        key: const Key('restTimerPlus'),
        onPressed: () => ctrl.addSeconds(15),
        child: Text(l10n.timerAddSeconds(15)),
      ),
      FilledButton.tonal(
        key: const Key('restTimerSkip'),
        onPressed: ctrl.stop,
        child: Text(l10n.timerSkip),
      ),
    ];

    return Material(
      color: scheme.secondaryContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (s.label != null && s.label!.isNotEmpty)
                Text(
                  s.label!,
                  style: Theme.of(context).textTheme.labelMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              if (widget.nextText != null && widget.nextText!.isNotEmpty)
                Text(
                  widget.nextText!,
                  key: const Key('restTimerNext'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              if (large)
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [time, ...buttons],
                )
              else
                Row(children: [time, const Spacer(), ...buttons]),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: LinearProgressIndicator(
                  key: const Key('restTimerProgress'),
                  value: s.progress(now),
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
