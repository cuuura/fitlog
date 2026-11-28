// 프로그램 추가(고르기) 시트. 프로그램 탭의 FAB와 홈의 "프로그램 시작하기"가 같은 시트를 연다.
// 템플릿·내 프로그램을 검색·타입·일수로 좁히고, 카드를 제자리에서 펼쳐 주 구조를 본 뒤 맞추기 화면으로 간다.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/program_dto.dart';
import '../../core/routes.dart';
import '../../core/theme.dart';
import '../../l10n/gen/app_localizations.dart';
import '../source_badge/source_badge.dart';
import 'program_common.dart';
import 'programs_providers.dart';

/// 시트를 열고, 고른 곳(맞추기·가져오기·예약)으로 시트를 닫은 뒤 이동한다.
Future<void> showProgramAddSheet(BuildContext context) async {
  final container = ProviderScope.containerOf(context);
  final route = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => const FractionallySizedBox(heightFactor: 1, child: ProgramAddSheet()),
  );
  if (route == null || !context.mounted) return;
  await context.push(route);
  container.invalidate(instanceListProvider);
}

/// 타입 칩 순서. 앞 3개는 항상 보이고 나머지는 목록에 있을 때만 보인다.
const _fixedTypes = ['BODYBUILDING', 'POWERBUILDING', 'POWERLIFTING'];
const _optionalTypes = ['GENERAL_STRENGTH', 'BODYWEIGHT'];

/// 일수 칩 값. 5는 "주 5일 이상".
const _dayChips = [3, 4, 5];

class ProgramAddSheet extends ConsumerStatefulWidget {
  const ProgramAddSheet({super.key});

  @override
  ConsumerState<ProgramAddSheet> createState() => _ProgramAddSheetState();
}

class _ProgramAddSheetState extends ConsumerState<ProgramAddSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  String? _type; // category 값. null이면 전체.
  int? _days; // 3 | 4 | 5(=5일 이상). null이면 전체.
  bool _builtIn = true; // 템플릿 | 내 프로그램
  String? _open; // 펼친 카드 id (한 번에 하나)

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _dayMatch(ProgramSummary p) => switch (_days) {
    null => true,
    5 => p.dayCount >= 5,
    final d => p.dayCount == d,
  };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final async = ref.watch(programListProvider);
    final running = {
      for (final i in ref.watch(instanceListProvider).value ?? const <Instance>[]) i.programId,
    };
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
            child: Row(
              children: [
                Expanded(child: Text(l.progAdd, style: Theme.of(context).textTheme.titleLarge)),
                IconButton(
                  key: const Key('program-add-close'),
                  tooltip: l.progAddClose,
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<bool>(
                key: const Key('program-add-segments'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: true, label: Text(l.progSegTemplates, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ButtonSegment(value: false, label: Text(l.progSegMine, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
                selected: {_builtIn},
                onSelectionChanged: (s) => setState(() {
                  _builtIn = s.first;
                  _type = null; // 구분마다 있는 타입이 달라 칩 선택은 비운다. 검색어·일수는 유지.
                  _open = null;
                }),
              ),
            ),
          ),
          Expanded(
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              // 프로그램 화면은 온라인 전용: 오프라인이면 안내와 다시 시도.
              error: (e, _) => ErrorRetry(error: e, onRetry: () => ref.invalidate(programListProvider)),
              data: (list) => _body(context, l, c, list, running),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l, AppColors c, List<ProgramSummary> list, Set<String> running) {
    final shown = [
      for (final p in list)
        if (p.builtIn == _builtIn) p,
    ];
    final present = {
      for (final p in shown)
        if (p.category != null) p.category!,
    };
    final types = [
      ..._fixedTypes,
      for (final t in _optionalTypes)
        if (present.contains(t)) t,
    ];
    final showChips = _builtIn || shown.any((p) => programCategoryLabel(l, p.category) != null);
    final selected = showChips && _type != null && types.contains(_type) ? _type : null;
    final q = _query.trim().toLowerCase();
    bool matches(ProgramSummary p) =>
        q.isEmpty ||
        p.name.toLowerCase().contains(q) ||
        (p.description ?? '').toLowerCase().contains(q) ||
        (p.templateKey ?? '').toLowerCase().contains(q);
    final filtered = [
      for (final p in shown)
        if ((selected == null || p.category == selected) && _dayMatch(p) && matches(p)) p,
    ];
    final emptyMsg = !_builtIn && shown.isEmpty
        ? l.progMineEmpty
        : selected != null && !shown.any((p) => p.category == selected)
        ? l.progEmptyType
        : l.progEmptySearch;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: TextField(
            key: const Key('programs-search'),
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: l.progSearchHint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      key: const Key('programs-search-clear'),
                      tooltip: l.progSearchClear,
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _query = '');
                      },
                    ),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
              isDense: true,
            ),
          ),
        ),
        if (showChips)
          SingleChildScrollView(
            key: const Key('programs-type-filter'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _chip(const Key('programs-type-all'), l.progTypeAll, selected == null, () => setState(() => _type = null)),
                for (final t in types)
                  _chip(
                    Key('programs-type-$t'),
                    programCategoryLabel(l, t)!,
                    selected == t,
                    () => setState(() => _type = selected == t ? null : t),
                  ),
              ],
            ),
          ),
        SingleChildScrollView(
          key: const Key('programs-days-filter'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _chip(const Key('programs-days-all'), l.progDaysAll, _days == null, () => setState(() => _days = null)),
              for (final d in _dayChips)
                _chip(
                  Key('programs-days-$d'),
                  d == 5 ? l.progDays5Plus : l.progWeekDays(d),
                  _days == d,
                  () => setState(() => _days = _days == d ? null : d),
                ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.refresh(programListProvider.future),
            child: ListView(
              key: const Key('program-add-list'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                if (filtered.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 8),
                    child: Text(emptyMsg, key: const Key('programs-empty'), textAlign: TextAlign.center),
                  )
                else
                  for (final p in filtered)
                    _PickCard(
                      key: Key('program-${p.id}'),
                      program: p,
                      running: running.contains(p.id),
                      open: _open == p.id,
                      onToggle: () => setState(() => _open = _open == p.id ? null : p.id),
                    ),
                const SizedBox(height: 12),
                _OtherWays(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _chip(Key key, String label, bool selected, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: FilterChip(key: key, label: Text(label), selected: selected, onSelected: (_) => onTap()),
    ),
  );
}

class _PickCard extends ConsumerWidget {
  const _PickCard({super.key, required this.program, required this.running, required this.open, required this.onToggle});
  final ProgramSummary program;
  final bool running;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    final p = program;
    final cat = programCategoryLabel(l, p.category);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: open ? c.accent : c.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              key: Key('program-toggle-${p.id}'),
              borderRadius: BorderRadius.circular(AppRadius.md),
              onTap: onToggle,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(p.name, style: text.titleSmall),
                                if (running) _RunningChip(key: Key('program-running-${p.id}')),
                                if (p.source == ProgramSource.AI_JSON || p.source == ProgramSource.AI_MCP)
                                  SourceBadge(
                                    key: Key('source-${p.id}'),
                                    source: p.source,
                                    importBatchId: p.importBatchId,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            // 서버가 수준·회당 시간·흔히 부르는 이름을 주면 이 줄에 칩으로 붙인다.
                            Text(
                              [l.progWeekDays(p.dayCount), ?cat].join(' · '),
                              style: text.bodySmall?.copyWith(color: c.fg2),
                            ),
                            if (p.description != null)
                              Text(
                                p.description!,
                                style: text.bodySmall?.copyWith(color: c.fg2),
                                maxLines: open ? null : 2,
                                overflow: open ? TextOverflow.visible : TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      Icon(open ? Icons.expand_less : Icons.expand_more, color: c.fg2),
                    ],
                  ),
                ),
              ),
            ),
            if (open) _Expanded(program: p),
          ],
        ),
      ),
    );
  }
}

class _RunningChip extends StatelessWidget {
  const _RunningChip({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(AppRadius.sm)),
      child: Text(
        AppLocalizations.of(context).progRunning,
        style: TextStyle(color: c.accentStrong, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 펼친 카드 안: 주 구조와 "이걸로 정하고 무게 맞추기".
class _Expanded extends ConsumerWidget {
  const _Expanded({required this.program});
  final ProgramSummary program;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final async = ref.watch(programViewProvider(program.id));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(height: 1, color: c.line),
          const SizedBox(height: 12),
          Text(l.progWeekStructure, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Column(
              children: [
                Text(errorMessage(l, e, fallback: l.programsLoadError), textAlign: TextAlign.center),
                const SizedBox(height: 8),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => ref.invalidate(programViewProvider(program.id)),
                  child: Text(l.commonRetry),
                ),
              ],
            ),
            data: (v) => Column(
              children: [
                for (final (i, day) in programDays(v.program.definition).indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 40,
                          child: Text(
                            day['weekday'] != null
                                ? weekdayLabel(l, day['weekday'] as String)
                                : (day['key'] as String? ?? '${i + 1}'),
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            [
                              for (final ex in (day['exercises'] as List? ?? const []).cast<Map>())
                                '${v.lifts[ex['lift']]?.name(context) ?? ex['lift']}  ${summarizeSets((ex['sets'] as List).cast())}'
                                    .trim(),
                            ].join('\n'),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: Key('program-pick-${program.id}'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.of(context).pop(Routes.programStart(program.id)),
            child: Text(l.progPickCta, textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }
}

/// 맨 아래 "다른 방법으로 추가". 직접 만들기는 편집기가 생기는 v1.2까지 숨긴다.
class _OtherWays extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    Widget tile(Key key, IconData icon, Color color, String title, String hint, String route) => ListTile(
      key: key,
      minVerticalPadding: 8,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, color: color),
      title: Text(title),
      subtitle: Text(hint),
      trailing: Icon(Icons.chevron_right, color: c.fg2),
      onTap: () => Navigator.of(context).pop(route),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(height: 1, color: c.line),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Text(l.progOtherWays, style: text.titleSmall),
        ),
        tile(const Key('programs-import-ai'), Icons.auto_awesome, c.ai, l.progImportAi, l.progOtherAiHint, Routes.importJson),
        tile(
          const Key('programs-scheduled-new'),
          Icons.event_outlined,
          c.fg2,
          l.progOtherScheduled,
          l.progOtherScheduledHint,
          Routes.scheduledNew,
        ),
      ],
    );
  }
}
