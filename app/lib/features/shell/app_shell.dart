import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/clock.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../exercise_picker/exercise_labels.dart';
import '../rest_timer/rest_timer_bar.dart' show formatRestRemaining;
import '../rest_timer/rest_timer_controller.dart';
import '../session/session_controller.dart';

/// 하단 4탭(오늘·기록·프로그램·나) 셸. 진행 중 세션이 있으면 내비 위에 미니바를 붙인다.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ActiveSessionMiniBar(),
          NavigationBar(
            key: const Key('app-nav'),
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: (i) => navigationShell.goBranch(i, initialLocation: i == navigationShell.currentIndex),
            destinations: [
              NavigationDestination(
                key: const Key('nav-today'),
                icon: const Icon(Icons.today_outlined),
                selectedIcon: const Icon(Icons.today),
                label: l.shellNavToday,
              ),
              NavigationDestination(
                key: const Key('nav-history'),
                icon: const Icon(Icons.history),
                label: l.shellNavHistory,
              ),
              NavigationDestination(
                key: const Key('nav-programs'),
                icon: const Icon(Icons.view_list_outlined),
                selectedIcon: const Icon(Icons.view_list),
                label: l.shellNavPrograms,
              ),
              NavigationDestination(
                key: const Key('nav-me'),
                icon: const Icon(Icons.person_outline),
                selectedIcon: const Icon(Icons.person),
                label: l.shellNavMe,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "진행 중 · 벤치 프레스 3/8세트 · 휴식 1:12". 누르면 진행 중 세션 화면.
class ActiveSessionMiniBar extends ConsumerStatefulWidget {
  const ActiveSessionMiniBar({super.key});

  @override
  ConsumerState<ActiveSessionMiniBar> createState() => _ActiveSessionMiniBarState();
}

class _ActiveSessionMiniBarState extends ConsumerState<ActiveSessionMiniBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
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
    final session = ref.watch(activeSessionProvider).value;
    if (session == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final names = ref.watch(exerciseMapProvider).value ?? const <String, Exercise>{};
    final rest = ref.watch(restTimerProvider);

    final total = session.exercises.fold<int>(0, (a, e) => a + e.sets.length);
    final done = session.exercises.fold<int>(0, (a, e) => a + e.sets.where((s) => s.completedAt != null).length);
    SessionExercise? current;
    for (final e in session.exercises) {
      if (e.sets.any((s) => s.completedAt == null)) {
        current = e;
        break;
      }
    }
    current ??= session.exercises.isEmpty ? null : session.exercises.last;
    final ex = current == null ? null : names[current.exerciseId];
    final name = ex == null ? '' : exerciseDisplayName(context, ex);

    var text = name.isEmpty
        ? l.shellMiniActive('', done, total).replaceAll('  ', ' ')
        : l.shellMiniActive(name, done, total);
    if (rest.running) {
      final left = rest.remaining(ref.read(clockProvider)());
      if (left > Duration.zero) text = '$text · ${l.shellMiniRest(_mmss(left))}';
    }
    return Material(
      color: c.accentSoft,
      child: InkWell(
        key: const Key('active-mini-bar'),
        onTap: () => context.push(Routes.session),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.fitness_center, size: 18, color: c.accentStrong),
                const SizedBox(width: 10),
                Expanded(
                  child: Semantics(
                    label: '${l.shellMiniOpen}. $text',
                    excludeSemantics: true,
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: c.accentStrong),
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, color: c.accentStrong),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _mmss(Duration d) => formatRestRemaining(d).replaceFirst(RegExp(r'^0'), '');
}
