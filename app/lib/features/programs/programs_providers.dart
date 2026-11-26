// B1 소유. 프로그램 화면의 읽기 Provider (온라인 전용, 화면을 벗어나면 버린다).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/program_dto.dart';
import '../../data/providers.dart';
import 'program_common.dart';

final programListProvider = FutureProvider.autoDispose<List<ProgramSummary>>(
  (ref) => ref.watch(programRepositoryProvider).listPrograms(),
);

/// ACTIVE·PAUSED 인스턴스만.
final instanceListProvider = FutureProvider.autoDispose<List<Instance>>((ref) async {
  final all = await ref.watch(programRepositoryProvider).listInstances();
  return [
    for (final i in all)
      if (i.status != InstanceStatus.FINISHED) i,
  ];
});

class ProgramView {
  const ProgramView(this.program, this.lifts);
  final Program program;
  final Map<String, LiftRef> lifts;
}

final programViewProvider = FutureProvider.autoDispose.family<ProgramView, String>((ref, id) async {
  final p = await ref.watch(programRepositoryProvider).getProgram(id);
  final lifts = await loadLiftRefs(ref.watch(exerciseRepositoryProvider), p.definition);
  return ProgramView(p, lifts);
});

class StartView {
  const StartView(this.program, this.lifts, this.suggestions);
  final Program program;
  final Map<String, LiftRef> lifts;
  final List<SuggestItem> suggestions;
}

final startViewProvider = FutureProvider.autoDispose.family<StartView, String>((ref, id) async {
  final repo = ref.watch(programRepositoryProvider);
  final p = await repo.getProgram(id);
  final suggestions = await repo.suggest(id);
  final lifts = await loadLiftRefs(ref.watch(exerciseRepositoryProvider), p.definition);
  return StartView(p, lifts, suggestions);
});

class InstanceView {
  const InstanceView({
    required this.instance,
    required this.program,
    required this.lifts,
    required this.plan,
    required this.accessories,
    required this.exerciseNames,
  });
  final Instance instance;
  final Program program;
  final Map<String, LiftRef> lifts;
  final List<PlannedWorkout> plan;
  final List<Accessory> accessories;

  /// 보조운동·계획 종목 id → 종목(없으면 null).
  final Map<String, LiftRef> exerciseNames;
}

final instanceViewProvider = FutureProvider.autoDispose.family<InstanceView, String>((ref, id) async {
  final repo = ref.watch(programRepositoryProvider);
  final exRepo = ref.watch(exerciseRepositoryProvider);
  final inst = await repo.getInstance(id);
  final program = await repo.getProgram(inst.programId);
  final plan = await repo.plan(id, count: 3);
  final acc = await repo.accessories(id);
  final lifts = await loadLiftRefs(exRepo, program.definition);
  final ids = <String>{
    for (final a in acc) a.exerciseId,
    for (final w in plan) for (final e in w.exercises) e.exerciseId,
  };
  final names = <String, LiftRef>{};
  for (final eid in ids) {
    names[eid] = LiftRef(await exRepo.byId(eid), eid);
  }
  return InstanceView(
    instance: inst,
    program: program,
    lifts: lifts,
    plan: plan,
    accessories: acc,
    exerciseNames: names,
  );
});
