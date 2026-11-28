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
import 'program_recommend.dart';
import 'programs_providers.dart';

/// 시트를 열고, 고른 곳(맞추기·가져오기·예약)으로 시트를 닫은 뒤 이동한다.
Future<void> showProgramAddSheet(BuildContext context) async {
  final container = ProviderScope.containerOf(context);
  final route = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) =>
        const FractionallySizedBox(heightFactor: 1, child: ProgramAddSheet()),
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

/// 수준 칩 값(서버 문자열).
const _levelChips = ['BEGINNER', 'INTERMEDIATE', 'ADVANCED'];

/// 카드 한 장. 같은 family 의 템플릿은 변형(variants)으로 묶인다. 하나뿐이면 일반 카드.
class _Group {
  _Group(this.key, this.variants);
  final String key; // family ?? id
  final List<ProgramSummary> variants;
  bool get multi => variants.length > 1;
}

List<_Group> _groupByFamily(List<ProgramSummary> list) {
  final byKey = <String, _Group>{};
  for (final p in list) {
    final k = p.family ?? p.id;
    (byKey[k] ??= _Group(k, [])).variants.add(p);
  }
  return byKey.values.toList();
}

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
  String? _level; // BEGINNER | INTERMEDIATE | ADVANCED. null이면 전체.
  final Map<String, String> _variant = {}; // 카드 키 → 고른 변형 id
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
      for (final i
          in ref.watch(instanceListProvider).value ?? const <Instance>[])
        i.programId,
    };
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l.progAdd,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  key: const Key('program-add-close'),
                  tooltip: l.progAddClose,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
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
                  ButtonSegment(
                    value: true,
                    label: Text(
                      l.progSegTemplates,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text(
                      l.progSegMine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                selected: {_builtIn},
                onSelectionChanged: (s) => setState(() {
                  _builtIn = s.first;
                  _type = null; // 구분마다 있는 타입이 달라 칩 선택은 비운다. 검색어·일수는 유지.
                  _level = null;
                  _open = null;
                }),
              ),
            ),
          ),
          Expanded(
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              // 프로그램 화면은 온라인 전용: 오프라인이면 안내와 다시 시도.
              error: (e, _) => ErrorRetry(
                error: e,
                onRetry: () => ref.invalidate(programListProvider),
              ),
              data: (list) => _body(context, l, c, list, running),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l,
    AppColors c,
    List<ProgramSummary> list,
    Set<String> running,
  ) {
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
    final showChips =
        _builtIn ||
        shown.any((p) => programCategoryLabel(l, p.category) != null);
    final selected = showChips && _type != null && types.contains(_type)
        ? _type
        : null;
    final q = _query.trim().toLowerCase();
    bool matches(ProgramSummary p) =>
        q.isEmpty ||
        p.name.toLowerCase().contains(q) ||
        (p.description ?? '').toLowerCase().contains(q) ||
        (p.templateKey ?? '').toLowerCase().contains(q) ||
        p.aka.any((a) => a.toLowerCase().contains(q));
    final filtered = [
      for (final p in shown)
        if ((selected == null || p.category == selected) &&
            _dayMatch(p) &&
            (_level == null || p.level == _level) &&
            matches(p))
          p,
    ];
    final groups = _groupByFamily(filtered);
    final filtering =
        q.isNotEmpty || selected != null || _days != null || _level != null;
    // 추천은 템플릿 구분에서 필터가 없을 때만. 읽기에 실패하거나 아직 읽는 중이면 숨긴다.
    final inputs = _builtIn && !filtering
        ? ref.watch(recommendInputsProvider).value
        : null;
    final rec = inputs == null
        ? null
        : recommendTemplates(
            templates: shown,
            weeklyAvg: inputs.weeklyAvg,
            hasOneRm: inputs.hasOneRm,
            runningIds: running,
          );
    final recGroups = <_Group>[];
    if (rec != null) {
      for (final p in rec.programs) {
        final all = p.family == null
            ? [p]
            : [
                for (final s in shown)
                  if (s.family == p.family) s,
              ];
        recGroups.add(_Group(p.family ?? p.id, all));
      }
    }
    final recKeys = {for (final g in recGroups) g.key};
    final emptyMsg = !_builtIn && shown.isEmpty
        ? l.progMineEmpty
        : selected != null && !shown.any((p) => p.category == selected)
        ? l.progEmptyType
        : l.progEmptySearch;
    // 칩 줄이 화면보다 짧아도 가운데로 가지 않게 왼쪽에 붙인다.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
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
                _chip(
                  const Key('programs-type-all'),
                  l.progTypeAll,
                  selected == null,
                  () => setState(() => _type = null),
                ),
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
              _chip(
                const Key('programs-days-all'),
                l.progDaysAll,
                _days == null,
                () => setState(() => _days = null),
              ),
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
        if (_builtIn)
          SingleChildScrollView(
            key: const Key('programs-level-filter'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _chip(
                  const Key('programs-level-all'),
                  l.progLevelAll,
                  _level == null,
                  () => setState(() => _level = null),
                ),
                for (final v in _levelChips)
                  _chip(
                    Key('programs-level-$v'),
                    programLevelLabel(l, v)!,
                    _level == v,
                    () => setState(() => _level = _level == v ? null : v),
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
                    padding: const EdgeInsets.symmetric(
                      vertical: 32,
                      horizontal: 8,
                    ),
                    child: Text(
                      emptyMsg,
                      key: const Key('programs-empty'),
                      textAlign: TextAlign.center,
                    ),
                  )
                else ...[
                  if (rec != null) ...[
                    _sectionTitle(
                      context,
                      l.progRecTitle,
                      key: const Key('program-rec-title'),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                      child: Text(
                        _recWhy(l, rec.reason),
                        key: const Key('program-rec-why'),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: c.fg2),
                      ),
                    ),
                    for (final (i, g) in recGroups.indexed)
                      _card(g, running, recId: rec.programs[i].id),
                    _sectionTitle(context, l.progAllTitle(shown.length)),
                  ],
                  for (final g in groups)
                    if (!recKeys.contains(g.key)) _card(g, running),
                ],
                const SizedBox(height: 12),
                _OtherWays(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String s, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
    child: Text(s, style: Theme.of(context).textTheme.titleSmall),
  );

  String _recWhy(AppLocalizations l, RecReason r) => switch (r.kind) {
    RecReasonKind.fresh => l.progRecWhyFresh,
    RecReasonKind.steadyBeginner => l.progRecWhySteadyBeginner(r.perWeek),
    RecReasonKind.steady => l.progRecWhySteady(r.perWeek),
    RecReasonKind.strong => l.progRecWhyStrong(r.perWeek),
  };

  /// 묶음 카드·일반 카드 한 장. recId 가 있으면 추천 카드(키 program-rec-ID, 펼침 상태는 따로).
  Widget _card(_Group g, Set<String> running, {String? recId}) {
    final stateKey = recId == null ? g.key : 'rec:${g.key}';
    final stored = _variant[stateKey] ?? recId;
    final sel = g.variants.firstWhere(
      (v) => v.id == stored,
      orElse: () => g.variants.first,
    );
    final multi = g.multi;
    final open = _open == stateKey;
    final Key cardKey = recId != null
        ? Key('program-rec-$recId')
        : multi
        ? Key('program-family-${g.key}')
        : Key('program-${sel.id}');
    final Key toggleKey = recId != null
        ? Key('program-rec-toggle-$recId')
        : multi
        ? Key('program-family-toggle-${g.key}')
        : Key('program-toggle-${sel.id}');
    return _PickCard(
      key: cardKey,
      toggleKey: toggleKey,
      variants: g.variants,
      selected: sel,
      running: running,
      open: open,
      onToggle: () => setState(() => _open = open ? null : stateKey),
      onSelect: (id) => setState(() => _variant[stateKey] = id),
    );
  }

  Widget _chip(Key key, String label, bool selected, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: FilterChip(
            key: key,
            label: Text(label),
            selected: selected,
            onSelected: (_) => onTap(),
          ),
        ),
      );
}

class _PickCard extends ConsumerWidget {
  const _PickCard({
    super.key,
    required this.toggleKey,
    required this.variants,
    required this.selected,
    required this.running,
    required this.open,
    required this.onToggle,
    required this.onSelect,
  });
  final Key toggleKey;
  final List<ProgramSummary> variants;
  final ProgramSummary selected;
  final Set<String> running;
  final bool open;
  final VoidCallback onToggle;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    final p = selected;
    final multi = variants.length > 1;
    final cat = programCategoryLabel(l, p.category);
    // 접힌 묶음 카드는 변형들의 일수·수준 범위를, 펼치면 고른 변형 기준을 보여 준다.
    final showRange = multi && !open;
    final days = [for (final v in variants) v.dayCount]..sort();
    final dayText = showRange && days.first != days.last
        ? l.progWeekDaysRange(days.first, days.last)
        : l.progWeekDays(p.dayCount);
    final levels =
        {
          for (final v in (showRange ? variants : [p]))
            if (programLevelLabel(l, v.level) != null) v.level!,
        }.toList()..sort(
          (a, b) => _levelChips.indexOf(a).compareTo(_levelChips.indexOf(b)),
        );
    final levelText = levels.isEmpty
        ? null
        : levels.length == 1
        ? programLevelLabel(l, levels.first)
        : '${programLevelLabel(l, levels.first)}~${programLevelLabel(l, levels.last)}';
    final isRunning = open
        ? running.contains(p.id)
        : variants.any((v) => running.contains(v.id));
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
              key: toggleKey,
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
                                if (isRunning)
                                  _RunningChip(
                                    key: Key('program-running-${p.id}'),
                                  ),
                                if (p.source == ProgramSource.AI_JSON ||
                                    p.source == ProgramSource.AI_MCP)
                                  SourceBadge(
                                    key: Key('source-${p.id}'),
                                    source: p.source,
                                    importBatchId: p.importBatchId,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [dayText, ?levelText, ?cat].join(' · '),
                              key: Key('program-meta-${p.id}'),
                              style: text.bodySmall?.copyWith(color: c.fg2),
                            ),
                            if (sessionMinutesText(l, p.sessionMinutes) case final m?)
                              Text(
                                m,
                                key: Key('program-session-minutes-${p.id}'),
                                style: text.bodySmall?.copyWith(color: c.fg2),
                              ),
                            if (p.description != null)
                              Text(
                                p.description!,
                                style: text.bodySmall?.copyWith(color: c.fg2),
                                maxLines: open ? null : 2,
                                overflow: open
                                    ? TextOverflow.visible
                                    : TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      Icon(
                        open ? Icons.expand_less : Icons.expand_more,
                        color: c.fg2,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (open)
              _Expanded(
                program: p,
                variants: variants,
                running: running,
                onSelect: onSelect,
              ),
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
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        AppLocalizations.of(context).progRunning,
        style: TextStyle(
          color: c.accentStrong,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 펼친 카드 안: 구성 칩(묶음일 때), 주 구조, 쉬운 말 규칙, "이걸로 정하고 무게 맞추기".
class _Expanded extends ConsumerWidget {
  const _Expanded({
    required this.program,
    required this.variants,
    required this.running,
    required this.onSelect,
  });
  final ProgramSummary program;
  final List<ProgramSummary> variants;
  final Set<String> running;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final async = ref.watch(programViewProvider(program.id));
    final rules = program.rules;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(height: 1, color: c.line),
          const SizedBox(height: 12),
          if (variants.length > 1) ...[
            Semantics(
              container: true,
              label: l.progVariantGroup,
              child: Wrap(
                key: const Key('program-variants'),
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final v in variants)
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: ChoiceChip(
                        key: Key('program-variant-${v.id}'),
                        label: Text(
                          [
                            v.variantLabel ?? l.progWeekDays(v.dayCount),
                            if (running.contains(v.id)) l.progRunning,
                          ].join(' · '),
                        ),
                        selected: v.id == program.id,
                        onSelected: (_) => onSelect(v.id),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (program.aka.isNotEmpty) ...[
            Text(
              l.progAka(program.aka.join(', ')),
              key: Key('program-aka-${program.id}'),
              style: theme.textTheme.bodySmall?.copyWith(color: c.fg2),
            ),
            const SizedBox(height: 8),
          ],
          Text(l.progWeekStructure, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Column(
              children: [
                Text(
                  errorMessage(l, e, fallback: l.programsLoadError),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: () =>
                      ref.invalidate(programViewProvider(program.id)),
                  child: Text(l.commonRetry),
                ),
              ],
            ),
            data: (v) => Column(
              children: [
                for (final (i, day) in programDays(
                  v.program.definition,
                ).indexed)
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
                              for (final ex
                                  in (day['exercises'] as List? ?? const [])
                                      .cast<Map>())
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
          if (rules != null) ...[
            const SizedBox(height: 8),
            Column(
              key: Key('program-rules-${program.id}'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ruleLine(theme, l.progRuleUp, rules.progress),
                _ruleLine(theme, l.progRuleFailLabel, rules.failure),
                _ruleLine(theme, l.progRuleDeloadLabel, rules.deload),
              ],
            ),
          ],
          const SizedBox(height: 8),
          FilledButton(
            key: Key('program-pick-${program.id}'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () =>
                Navigator.of(context).pop(Routes.programStart(program.id)),
            child: Text(l.progPickCta, textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }

  /// 라벨과 서버 문구를 한 문단으로(줄바꿈이 자연스럽고 큰 글씨에서도 넘치지 않는다).
  Widget _ruleLine(ThemeData theme, String label, String body) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(text: label, style: theme.textTheme.titleSmall),
          const TextSpan(text: '  '),
          TextSpan(text: body),
        ],
      ),
    ),
  );
}

/// 맨 아래 "다른 방법으로 추가". 직접 만들기는 편집기가 생기는 v1.2까지 숨긴다.
class _OtherWays extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = AppColors.of(context);
    final text = Theme.of(context).textTheme;
    Widget tile(
      Key key,
      IconData icon,
      Color color,
      String title,
      String hint,
      String route,
    ) => ListTile(
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
        tile(
          const Key('programs-import-ai'),
          Icons.auto_awesome,
          c.ai,
          l.progImportAi,
          l.progOtherAiHint,
          Routes.importJson,
        ),
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
