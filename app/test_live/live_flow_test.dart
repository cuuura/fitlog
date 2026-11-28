// 실제 서버를 상대로 한 계약 테스트. 앱이 쓰는 ApiClient·DTO·저장소·동기화 엔진 그대로 사용한다.
// 모든 응답이 앱의 DTO로 파싱돼야 한다(= 가짜 서버로는 못 잡는 앱↔서버 불일치를 잡는 것이 목적).
// 테스트는 위에서 아래로 한 계정의 흐름을 따라간다(앞 단계가 실패하면 뒤는 의미 없다).
import 'dart:math';

import 'package:drift/drift.dart' show driftRuntimeOptions;

import 'package:fitlog/core/api/ai_dto.dart';
import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/core/auth/auth_controller.dart';
import 'package:fitlog/core/auth/token_store.dart';
import 'package:fitlog/core/config.dart';
import 'package:fitlog/core/ids.dart';
import 'package:fitlog/domain/repositories.dart';
import 'package:flutter_test/flutter_test.dart';

import 'live_env.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  if (liveBaseUrl == null) {
    test('live 계약 테스트', () {}, skip: liveSkipReason);
    return;
  }

  late LiveApp app;
  late String username;
  const password = 'live-pass-1234';
  late String exerciseId; // 바벨 종목(서버 기본 종목)
  late String instanceId;
  late int plannedSeq; // 이번에 기록하는 회차의 planSeq
  late String sessionId;
  late String batchId;
  late String aiSessionId;
  final bodyId = newId();

  setUpAll(() {
    app = LiveApp.create();
    username = 'live${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${Random().nextInt(9999)}';
  });
  tearDownAll(() async => app.dispose());

  Future<void> syncOk(LiveApp a) async {
    await a.engine.syncNow();
    final st = await a.engine.watchStatus().first;
    expect(st.phase, SyncPhase.idle, reason: 'sync 실패: ${st.lastError}');
    expect(st.pending, 0, reason: 'outbox가 비지 않음 (${st.lastError})');
  }

  group('인증·동의', () {
    test('GET /health, GET /v1/auth/methods 가 AuthMethods로 파싱된다', () async {
      final m = await app.api.authMethods();
      expect(m.google, isTrue);
      expect(m.password, isTrue, reason: '서버를 PASSWORD_LOGIN_ENABLED=true 로 띄워야 한다');
      expect(m.passwordSignup, isTrue, reason: 'PASSWORD_SIGNUP_CODE 가 필요하다');
      final r = await app.dio.get<String>('/health');
      expect(r.data, 'ok');
    });

    test('가입 → 필수 동의 화면 상태(needsConsent)', () async {
      await app.auth.registerWithPassword(username, password, liveSignupCode, displayName: '라이브');
      expect(app.authStatus, AuthStatus.needsConsent);
      final me = app.auth.me!;
      expect(me.username, username);
      expect(me.role, UserRole.MEMBER);
      expect(me.consentsRequired.toSet(), ConsentKind.values.toSet());
    });

    test('서버 오류 JSON({error:{code,message,field}})이 ApiException으로 온다', () async {
      try {
        await app.api.postConsent(const ConsentInput(kind: ConsentKind.TERMS, version: '', granted: true));
        fail('400이어야 한다');
      } on ApiException catch (e) {
        expect(e.statusCode, 400);
        expect(e.code, 'VALIDATION_FAILED');
        expect(e.field, 'version');
        expect(e.message, isNotEmpty);
      }
    });

    test('앱 상수 AppConfig.consentVersion 으로 동의하면 signedIn 이 된다', () async {
      await app.auth.acceptConsents(AppConfig.consentVersion);
      expect(app.authStatus, AuthStatus.signedIn, reason: '앱 동의 버전(${AppConfig.consentVersion})이 서버 요구와 다르다');
      final cs = await app.api.getConsents();
      expect(cs.map((c) => c.kind).toSet(), ConsentKind.values.toSet());
      expect(cs.every((c) => c.granted && c.version == AppConfig.consentVersion), isTrue);
    });

    test('액세스 토큰이 깨져도 인터셉터가 refresh 후 재시도한다', () async {
      final t = app.tokens.tokens!;
      app.tokens.tokens = StoredTokens(
        accessToken: 'garbage.token.value',
        refreshToken: t.refreshToken,
        expiresAt: t.expiresAt,
      );
      final me = await app.api.getMe();
      expect(me.username, username);
      expect(app.tokens.tokens!.accessToken, isNot('garbage.token.value'));
      expect(app.tokens.tokens!.refreshToken, isNot(t.refreshToken), reason: '리프레시 토큰은 회전한다');
    });

    test('같은 아이디로 다시 가입하면 409(usernameTaken), 잘못된 비밀번호는 401(badCredentials)', () async {
      final other = LiveApp.create();
      addTearDown(other.dispose);
      await expectLater(
        other.auth.registerWithPassword(username, password, liveSignupCode),
        throwsA(isA<AuthFailure>().having((f) => f.kind, 'kind', AuthFailureKind.usernameTaken)),
      );
      await expectLater(
        other.auth.signInWithPassword(username, 'wrong-password-1'),
        throwsA(isA<AuthFailure>().having((f) => f.kind, 'kind', AuthFailureKind.badCredentials)),
      );
      await expectLater(
        other.auth.registerWithPassword('x${username}2', password, 'wrong-code'),
        throwsA(isA<AuthFailure>().having((f) => f.kind, 'kind', AuthFailureKind.signupCodeWrong)),
      );
    });
  });

  group('설정·종목', () {
    test('설정 GET/PUT 왕복(heightCm 소수, null 비우기)', () async {
      final s0 = await app.api.getSettings();
      expect(s0.weightUnit, WeightUnit.KG);
      final s1 = await app.api.putSettings(
        s0.copyWith(heightCm: () => 175.5, sex: () => Sex.MALE, birthYear: () => 1990, e1rmFormula: E1rmFormula.BRZYCKI),
      );
      expect(s1.heightCm, 175.5);
      expect(s1.sex, Sex.MALE);
      expect(s1.e1rmFormula, E1rmFormula.BRZYCKI);
      final s2 = await app.api.putSettings(s1.copyWith(heightCm: () => null, sex: () => null, e1rmFormula: E1rmFormula.EPLEY));
      expect(s2.heightCm, isNull);
      expect(s2.sex, isNull);
      expect(s2.e1rmFormula, E1rmFormula.EPLEY);
    });

    test('기본 종목 전체가 Exercise로 파싱되고 필터(muscle/type/q)가 동작한다', () async {
      final all = await app.api.getExercises();
      expect(all, isNotEmpty);
      expect(all.every((e) => e.builtIn), isTrue);
      final barbell = await app.api.getExercises(type: ExerciseType.BARBELL);
      expect(barbell, isNotEmpty);
      expect(barbell.every((e) => e.type == ExerciseType.BARBELL), isTrue);
      exerciseId = barbell.first.id;
      final chest = await app.api.getExercises(muscle: Muscle.CHEST);
      expect(chest.every((e) => e.primaryMuscle == Muscle.CHEST || e.secondaryMuscles.contains(Muscle.CHEST)), isTrue);
      expect(await app.api.getExercises(q: barbell.first.nameKo.substring(0, 1)), isNotEmpty);
    });

    test('내 종목 생성(저장소·outbox) → sync push → 서버 목록에 나온다 → 삭제', () async {
      final input = ExerciseInput(
        id: newId(),
        nameKo: '라이브 종목 ${Random().nextInt(100000)}',
        type: ExerciseType.DUMBBELL,
        primaryMuscle: Muscle.BICEPS,
        secondaryMuscles: const [Muscle.FOREARMS],
      );
      await app.exercises.createCustom(input);
      await syncOk(app);
      final mine = (await app.api.getExercises()).where((e) => e.id == input.id).single;
      expect(mine.builtIn, isFalse);
      expect(mine.secondaryMuscles, [Muscle.FOREARMS]);
      await app.exercises.deleteCustom(input.id);
      await syncOk(app);
      expect((await app.api.getExercises()).where((e) => e.id == input.id), isEmpty);
    });
  });

  group('프로그램·인스턴스', () {
    late List<ProgramSummary> templates;

    test('프로그램 목록·상세·suggest 가 모두 파싱된다(템플릿 전부)', () async {
      final list = await app.api.getPrograms();
      templates = await app.api.getPrograms(source: ProgramListSource.TEMPLATE);
      expect(templates, isNotEmpty);
      expect(templates.every((p) => p.builtIn && p.source == ProgramSource.TEMPLATE), isTrue);
      expect(list.length, greaterThanOrEqualTo(templates.length));
      expect(await app.api.getPrograms(source: ProgramListSource.MINE), isEmpty);
      for (final t in templates) {
        final p = await app.api.getProgram(t.id);
        expect(p.definition['days'], isA<List>(), reason: t.name);
        expect(p.dayCount, (p.definition['days'] as List).length);
        final sg = await app.api.suggest(t.id);
        expect(sg.every((s) => s.key.isNotEmpty), isTrue, reason: t.name);
      }
    });

    test('v1.1 시작 전 미리 계산·자동 계산·요일 바꾸기가 실서버와 맞는다(템플릿 전부)', () async {
      for (final t in templates) {
        expect(t.sessionMinutes, isNotNull, reason: t.name);
        final sg = await app.api.suggest(t.id);
        final tm = <String, double>{}, working = <String, double>{};
        for (final s in sg) {
          if (s.optional) continue;
          (s.needs == SuggestNeeds.TM ? tm : working)[s.key] = s.suggestedKg ?? 100;
        }
        final detail = await app.api.getProgram(t.id);
        final days = [for (final d in (detail.definition['days'] as List)) (d as Map)['key'] as String];
        const codes = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
        final wd = {for (var i = 0; i < days.length && i < 7; i++) days[i]: codes[i]};
        final pv = await app.api.previewStart(
          t.id,
          StartPreviewRequest(startDate: DateTime.now(), tz: 'Asia/Seoul', tm: tm, working: working, weekdays: days.length <= 7 ? wd : const {}),
        );
        expect(pv.workouts, hasLength(1), reason: t.name);
        expect(pv.workouts.first.exercises, isNotEmpty, reason: t.name);
        expect(pv.workouts.first.estimatedMinutes, isNotNull, reason: t.name);
        // from 이 비울 수 있는 키라 비워 보냈으면 파생 키도 비운 채(첫 운동에서 정하기)
        for (final d in sg.where((s) => s.derivedFrom != null && (tm.containsKey(s.derivedFrom) || working.containsKey(s.derivedFrom)))) {
          expect(pv.derived, contains(d.key), reason: '${t.name} ${d.key}');
        }
      }
    });

    test('인스턴스 시작(소수 무게 102.5) → 조회·목록·plan', () async {
      final t = templates.first;
      final sg = await app.api.suggest(t.id);
      final tm = <String, double>{}, working = <String, double>{};
      for (final s in sg) {
        (s.needs == SuggestNeeds.TM ? tm : working)[s.key] = s.suggestedKg ?? 102.5;
      }
      instanceId = newId();
      final started = await app.programs.startInstance(
        StartInstance(id: instanceId, programId: t.id, startDate: DateTime.now(), tz: 'Asia/Seoul', tm: tm, working: working),
      );
      expect(started.id, instanceId);
      expect(started.status, InstanceStatus.ACTIVE);
      expect(started.skipPolicy, SkipPolicy.SHIFT);
      expect(started.next, isNotNull);

      final got = await app.api.getInstance(instanceId);
      expect(got.state.seq, 0);
      expect((await app.api.getInstances(status: InstanceStatus.ACTIVE)).map((i) => i.id), contains(instanceId));

      final plan = await app.api.getPlan(instanceId, count: 3);
      expect(plan, hasLength(3));
      expect(plan.first.exercises, isNotEmpty);
      expect(plan.first.confirmed, isTrue);
      expect(plan.first.exercises.first.sets, isNotEmpty);
      expect((await app.api.getPlan(instanceId, count: 8)), hasLength(8));
      await expectLater(
        app.api.getPlan(instanceId, count: 9),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'VALIDATION_FAILED')),
      );
    });

    test('인스턴스 PATCH(status·adjust)와 보조운동 GET/PUT', () async {
      final inst = await app.api.getInstance(instanceId);
      if (inst.state.tm.isNotEmpty) {
        final k = inst.state.tm.keys.first;
        final p = await app.api.patchInstance(instanceId, InstancePatch(adjustTm: {k: 105.5}));
        expect(p.state.tm[k], 105.5);
      }
      final paused = await app.api.patchInstance(instanceId, const InstancePatch(status: InstanceStatus.PAUSED));
      expect(paused.status, InstanceStatus.PAUSED);
      final active = await app.api.patchInstance(instanceId, const InstancePatch(status: InstanceStatus.ACTIVE));
      expect(active.status, InstanceStatus.ACTIVE);
      expect(await app.api.getAccessories(instanceId), isEmpty);
      final dayKey = (await app.api.getPlan(instanceId, count: 1)).first.dayKey;
      final saved = await app.api.putAccessories(instanceId, [
        Accessory(id: newId(), dayKey: dayKey, exerciseId: exerciseId, position: 0, sets: 3, reps: 10, weightKg: 22.5),
      ]);
      expect(saved.single.weightKg, 22.5);
      await app.api.putAccessories(instanceId, const []);
    });
  });

  group('세션 기록 → sync', () {
    test('앱이 하는 대로: 프로그램 회차로 세션 시작 → 세트 완료(102.5kg) → 종료 → push', () async {
      final plan = (await app.api.getPlan(instanceId, count: 1)).single;
      plannedSeq = plan.planSeq;
      final s = await app.sessions.startSession(tz: 'Asia/Seoul', plan: plan);
      sessionId = s.id;
      var cur = (await app.sessions.watchSession(sessionId).first)!;
      expect(cur.exercises, isNotEmpty);
      final now = DateTime.now().toUtc();
      for (final se in cur.exercises) {
        for (final w in se.sets) {
          await app.sessions.updateSet(
            w.copyWith(
              weightKg: () => w.weightKg ?? 102.5,
              reps: () => w.reps ?? w.targetReps ?? 5,
              completedAt: () => now,
            ),
          );
        }
      }
      // 자유 종목 하나 더(소수 무게)
      final extra = await app.sessions.addExercise(sessionId, exerciseId);
      await app.sessions.addSet(
        extra.id,
        WorkoutSet(id: newId(), position: 0, weightKg: 102.5, reps: 5, rpe: 8.5, completedAt: now, restSec: 120, note: '라이브'),
      );
      await app.sessions.endSession(sessionId);
      cur = (await app.sessions.watchSession(sessionId).first)!;
      expect(cur.isActive, isFalse);
      await syncOk(app);
    });

    test('서버가 같은 세션을 DTO로 돌려준다(GET /sessions, /sessions/{id}, /exercises/{id}/last)', () async {
      final s = await app.api.getSession(sessionId);
      expect(s.programInstanceId, instanceId);
      expect(s.planSeq, plannedSeq);
      expect(s.source, SessionSource.APP);
      expect(s.endedAt, isNotNull);
      final free = s.exercises.where((e) => e.liftKey == null).single;
      expect(free.sets.single.weightKg, 102.5);
      expect(free.sets.single.rpe, 8.5);
      final list = await app.api.getSessions(limit: 5);
      expect(list.map((e) => e.id), contains(sessionId));
      expect((await app.api.getSessions(before: DateTime.now().toUtc().add(const Duration(minutes: 1)))).isNotEmpty, isTrue);
      final last = await app.api.getLastSets(exerciseId);
      expect(last, isNotNull);
      expect(last!.sets.first.weightKg, 102.5);
      expect(await app.api.getLastSets(newId()), isNull, reason: '기록 없는 종목은 404 → null');
    });

    test('프로그램이 서버에서 다음 회차로 넘어갔다(replay)', () async {
      final inst = await app.api.getInstance(instanceId);
      expect(inst.next!.planSeq, plannedSeq + 1, reason: '기록한 회차 다음으로 넘어가야 한다');
    });

    test('다른 기기(빈 로컬 DB)가 sync pull 로 같은 세션을 받는다', () async {
      final other = LiveApp.create(tokens: app.tokens);
      addTearDown(other.dispose);
      await syncOk(other);
      final got = await other.sessions.watchSession(sessionId).first;
      expect(got, isNotNull);
      expect(got!.programInstanceId, instanceId);
      final free = got.exercises.where((e) => e.liftKey == null).single;
      expect(free.sets.single.weightKg, 102.5);
      expect(free.sets.single.rpe, 8.5);
      expect(free.sets.single.completedAt, isNotNull);
      final prog = got.exercises.where((e) => e.liftKey != null);
      expect(prog, isNotEmpty);
      expect(prog.first.sets.first.plannedSetKey, isNotNull);
      expect(prog.first.sets.first.targetReps, isNotNull);
      expect(await other.db.getLastServerSeq(), greaterThan(0));
    });
  });

  group('기록·통계', () {
    test('records / one-rm / progress / comparison 이 파싱된다', () async {
      final r = await app.api.getRecords(exerciseId);
      expect(r.bestWeight, isNotNull);
      expect(r.bestWeight!.weightKg, 102.5);
      expect(r.formula, 'EPLEY');
      expect(r.byReps, isNotEmpty);

      final m = OneRmMeasurement(id: newId(), weightKg: 120.5, measuredAt: DateTime.now().toUtc(), note: '라이브');
      final saved = await app.api.postOneRm(exerciseId, m);
      expect(saved.weightKg, 120.5);
      expect(saved.exerciseId, exerciseId);
      expect((await app.api.getOneRms(exerciseId)).map((x) => x.id), contains(m.id));
      expect((await app.api.getRecords(exerciseId)).latestMeasured?.weightKg, 120.5);
      await app.api.deleteOneRm(m.id);

      final p = await app.api.getProgress(exerciseId, limit: 50);
      expect(p.points, isNotEmpty);
      expect(p.points.first.topWeightKg, 102.5);
      expect(p.points.first.isWeightPr, isTrue);
      expect(p.bestWeight, isNotNull);
      final pr = await app.api.getProgress(
        exerciseId,
        from: DateTime.now().toUtc().subtract(const Duration(days: 30)),
        to: DateTime.now().toUtc().add(const Duration(days: 1)),
      );
      expect(pr.points, isNotEmpty);

      final c = await app.api.getComparison(sessionId);
      expect(c.sessionId, sessionId);
      expect(c.exercises, isNotEmpty);
      expect(c.exercises.first.current.sets, isNotEmpty);
    });
  });

  group('내 프로그램·내 종목 REST', () {
    test('프로그램 검증(validate) → 저장 → 목록(MINE) → 시작 → skip → 삭제', () async {
      final def = {
        'schemaVersion': 1,
        'name': '라이브 프로그램 ${Random().nextInt(100000)}',
        'lifts': {
          'squat': {'exercise': {'id': exerciseId}},
        },
        'progression': {
          'squat': {'type': 'LINEAR', 'incrementKg': 2.5},
        },
        'days': [
          {
            'key': 'A',
            'name': 'A',
            'exercises': [
              {
                'lift': 'squat',
                'sets': [
                  {'count': 3, 'reps': 5, 'load': {'type': 'WORKING'}},
                ],
              },
            ],
          },
        ],
      };
      final v = await app.api.validateProgram(def);
      expect(v.id, '', reason: 'validate 응답은 id 가 없다');
      expect(v.dayCount, 1);
      final id = newId();
      final p = await app.api.postProgram(id, def);
      expect(p.id, id);
      expect(p.source, ProgramSource.USER);
      expect(p.builtIn, isFalse);
      expect((await app.api.getPrograms(source: ProgramListSource.MINE)).map((x) => x.id), contains(id));

      final sg = await app.api.suggest(id);
      expect(sg, isNotEmpty);
      final inst = newId();
      final started = await app.api.startInstance(
        StartInstance(
          id: inst,
          programId: id,
          startDate: DateTime.now(),
          tz: 'Asia/Seoul',
          skipPolicy: SkipPolicy.SHIFT,
          working: {for (final s in sg) s.key: 80.5},
        ),
      );
      final next = started.next!;
      final skipped = await app.api.skip(inst, next.planSeq);
      expect(skipped.next!.planSeq, greaterThan(next.planSeq));
      await app.api.deleteInstance(inst);
      await app.api.deleteProgram(id);
      expect((await app.api.getPrograms(source: ProgramListSource.MINE)).where((x) => x.id == id), isEmpty);
    });

    test('잘못된 프로그램은 400 VALIDATION_FAILED + details 로 온다', () async {
      try {
        await app.api.validateProgram({'schemaVersion': 1, 'name': 'x', 'lifts': {}, 'days': []});
        fail('400이어야 한다');
      } on ApiException catch (e) {
        expect(e.code, 'VALIDATION_FAILED');
        expect(e.details.isNotEmpty || e.message.isNotEmpty, isTrue);
      }
    });

    test('종목 REST 생성·수정·삭제(POST/PUT/DELETE /exercises)', () async {
      final input = ExerciseInput(
        id: newId(),
        nameKo: '라이브 REST ${Random().nextInt(100000)}',
        nameEn: 'Live REST',
        type: ExerciseType.MACHINE,
        primaryMuscle: Muscle.BACK,
        secondaryMuscles: const [Muscle.BICEPS],
      );
      final created = await app.api.postExercise(input);
      expect(created.builtIn, isFalse);
      expect(created.nameEn, 'Live REST');
      final updated = await app.api.putExercise(
        ExerciseInput(id: input.id, nameKo: '${input.nameKo}!', type: ExerciseType.MACHINE, primaryMuscle: Muscle.LATS),
      );
      expect(updated.primaryMuscle, Muscle.LATS);
      expect(updated.nameEn, isNull);
      await app.api.deleteExercise(input.id);
      try {
        await app.api.deleteExercise(exerciseId);
        fail('기본 종목은 지울 수 없다');
      } on ApiException catch (e) {
        expect(e.statusCode, 403);
        expect(e.code, 'FORBIDDEN');
      }
    });
  });

  group('체중', () {
    test('앱 저장소로 기록(70.5kg) → push → GET /body/measurements 파싱 → 다른 기기 pull', () async {
      final at = DateTime.now().toUtc();
      await app.body.add(BodyMeasurement(id: bodyId, measuredAt: at, weightKg: 70.5));
      await syncOk(app);
      final list = await app.api.getMeasurements();
      final m = list.singleWhere((x) => x.id == bodyId);
      expect(m.weightKg, 70.5);
      expect(m.source, MeasurementSource.MANUAL);
      expect(
        (await app.api.getMeasurements(from: at.subtract(const Duration(days: 1)), to: at.add(const Duration(days: 1)))),
        isNotEmpty,
      );
      final other = LiveApp.create(tokens: app.tokens);
      addTearDown(other.dispose);
      await syncOk(other);
      final got = await other.body.watchMeasurements().first;
      expect(got.singleWhere((x) => x.id == bodyId).weightKg, 70.5);
    });

    test('REST POST/DELETE 체중도 DTO로 왕복한다', () async {
      final id = newId();
      final saved = await app.api.postMeasurement(BodyMeasurement(id: id, measuredAt: DateTime.now().toUtc(), weightKg: 80.25));
      expect(saved.weightKg, 80.25);
      await app.api.deleteMeasurement(id);
      expect((await app.api.getMeasurements()).where((x) => x.id == id), isEmpty);
    });
  });

  group('AI 가져오기·삭제 요청·연결', () {
    test('미리보기 → 저장 → 이력·상세 파싱 (세션·체중·프로그램 묶음)', () async {
      final started = DateTime.now().toUtc().subtract(const Duration(days: 40));
      aiSessionId = newId();
      final bundle = {
        'schemaVersion': 1,
        'note': '라이브 테스트',
        'sessions': [
          {
            'id': aiSessionId,
            'startedAt': started.toIso8601String(),
            'tz': 'Asia/Seoul',
            'exercises': [
              {
                'exercise': {'id': exerciseId},
                'sets': [
                  {'weightKg': 97.5, 'reps': 5},
                  {'weightKg': 100, 'reps': 3, 'rpe': 9},
                ],
              },
            ],
          },
        ],
        'bodyMeasurements': [
          {'measuredAt': started.toIso8601String(), 'weightKg': 71.2},
        ],
      };
      final req = ImportRequest(bundle: bundle, clientName: 'Claude', tz: 'Asia/Seoul');
      final pv = await app.api.previewImport(req);
      expect(pv.valid, isTrue);
      expect(pv.conflicts, isEmpty);
      expect(pv.counts['sessions']?['NEW'], 1);

      final out = await app.imports.submit(req);
      expect(out.saved, isTrue, reason: 'preview=${out.preview?.conflicts.map((c) => c.code)}');
      batchId = out.batch!.id;
      expect(out.batch!.channel, ImportChannel.APP_JSON);
      expect(out.batch!.clientName, 'Claude');
      expect(out.batch!.summary['sessions'], 1);

      // 같은 묶음을 다시 보내도 멱등(200, UNCHANGED)
      final again = await app.api.submitImport(req);
      expect(again.saved, isTrue);

      final history = await app.api.getImports();
      expect(history.map((b) => b.id), contains(batchId));
      final detail = await app.api.getImport(batchId);
      expect(detail.items.any((i) => i.entity == 'workout_session' && i.action == ImportItemAction.CREATED), isTrue);
    });

    test('가져온 세션이 REST(GET /sessions/{id})에 AI_JSON 출처로 붙는다', () async {
      final s = await app.api.getSession(aiSessionId);
      expect(s.source, SessionSource.AI_JSON);
      expect(s.importBatchId, batchId);
      expect(s.isFromAi, isTrue);
    });

    test('다른 기기가 sync pull 로 받은 AI 세션·체중에도 출처 배지용 source/importBatchId 가 있다', () async {
      final other = LiveApp.create(tokens: app.tokens);
      addTearDown(other.dispose);
      await syncOk(other);
      final s = await other.sessions.watchSession(aiSessionId).first;
      expect(s, isNotNull, reason: '가져온 세션이 pull 로 내려와야 한다');
      expect(s!.source, SessionSource.AI_JSON, reason: '앱 히스토리의 AI 배지는 로컬 DB source 로 판단한다');
      expect(s.importBatchId, batchId);
      final bodies = await other.body.watchMeasurements().first;
      final ai = bodies.where((m) => m.source == MeasurementSource.AI_JSON);
      expect(ai, isNotEmpty);
      expect(ai.first.importBatchId, batchId);
    });

    test('잘못된 묶음은 400 VALIDATION_FAILED + details(JSON 포인터)로 온다', () async {
      try {
        await app.api.previewImport(const ImportRequest(bundle: {'schemaVersion': 1, 'sessions': [{}]}));
        fail('400이어야 한다');
      } on ApiException catch (e) {
        expect(e.statusCode, 400);
        expect(e.code, 'VALIDATION_FAILED');
        expect(e.details, isNotEmpty);
        expect(e.details.first.path, startsWith('/'));
      }
    });

    test('모르는 종목 이름은 409 CONFLICT_UNRESOLVED → ImportPreview(needsResolution)', () async {
      final req = ImportRequest(
        bundle: {
          'schemaVersion': 1,
          'sessions': [
            {
              'startedAt': DateTime.now().toUtc().subtract(const Duration(days: 80)).toIso8601String(),
              'exercises': [
                {
                  'exercise': {'name': '존재하지않는종목-${Random().nextInt(99999)}'},
                  'sets': [
                    {'weightKg': 10, 'reps': 5},
                  ],
                },
              ],
            },
          ],
        },
        tz: 'Asia/Seoul',
      );
      final out = await app.api.submitImport(req);
      expect(out.saved, isFalse);
      final c = out.preview!.conflicts.single;
      expect(c.code, ConflictCode.UNKNOWN_EXERCISE);
      expect(c.allowed, containsAll([ResolutionAction.MAP_TO, ResolutionAction.CREATE, ResolutionAction.SKIP]));
      final resolved = await app.api.submitImport(
        req.withResolutions({c.conflictId: const Resolution(ResolutionAction.SKIP)}),
      );
      expect(resolved.saved, isTrue);
    });

    test('되돌리기(revert) 후 pull 하면 AI 세션이 로컬에서도 사라진다', () async {
      final reverted = await app.imports.revert(batchId);
      expect(reverted.isReverted, isTrue);
      await syncOk(app);
      expect(await app.sessions.watchSession(aiSessionId).first, isNull);
    });

    test('삭제 요청 목록·건수, AI 연결, MCP 안내, 공개 스키마가 파싱된다', () async {
      expect(await app.deletions.list(), isEmpty);
      for (final st in DeletionStatus.values) {
        expect(await app.api.getDeletionRequests(status: st), isEmpty);
      }
      expect(await app.deletions.pendingCount(), 0);
      expect(await app.ai.connections(), isEmpty);
      final info = await app.ai.mcpInfo();
      expect(info.mcpUrl, endsWith('/mcp'));
      expect(info.clients, isNotEmpty);
      expect(info.clients.every((c) => c.steps.isNotEmpty), isTrue);
      final schema = await app.dio.getUri<Object>(Uri.parse(app.api.importSchemaUrl));
      expect(schema.statusCode, 200);
      expect((await app.dio.getUri<Object>(Uri.parse(app.api.programSchemaUrl))).statusCode, 200);
    });

    test('내보내기(JSON·CSV)', () async {
      final json = await app.export.exportJson();
      expect(json, contains('"schemaVersion"'));
      expect((await app.export.exportCsv(CsvKind.sets)).startsWith('﻿'), isTrue);
      expect((await app.export.exportCsv(CsvKind.body)).startsWith('﻿'), isTrue);
    });
  });

  group('정리·로그아웃·계정 삭제', () {
    test('인스턴스·세션 삭제(REST)', () async {
      await app.api.deleteSession(sessionId);
      await app.programs.deleteInstance(instanceId);
      expect((await app.api.getInstances()).where((i) => i.id == instanceId), isEmpty);
      await syncOk(app);
    });

    test('로그아웃은 서버의 리프레시 토큰을 실제로 폐기한다(Bearer 필요)', () async {
      final refresh = app.tokens.tokens!.refreshToken;
      await app.auth.signOut();
      expect(app.authStatus, AuthStatus.signedOut);
      final fresh = LiveApp.create();
      addTearDown(fresh.dispose);
      await expectLater(
        fresh.api.authRefresh(refresh),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
        reason: '로그아웃 후에도 리프레시 토큰이 살아 있다 = 앱이 /auth/logout 에 Bearer 를 안 붙임',
      );
    });

    test('액세스 토큰이 만료된 뒤 로그아웃해도 서버의 리프레시 토큰이 폐기된다', () async {
      final a = LiveApp.create();
      addTearDown(a.dispose);
      await a.auth.signInWithPassword(username, password);
      final t = a.tokens.tokens!;
      a.tokens.tokens = StoredTokens(accessToken: 'expired.access.token', refreshToken: t.refreshToken, expiresAt: t.expiresAt);
      await a.auth.signOut();
      expect(a.authStatus, AuthStatus.signedOut);
      final fresh = LiveApp.create();
      addTearDown(fresh.dispose);
      await expectLater(
        fresh.api.authRefresh(t.refreshToken),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
      );
      // refresh 로 회전된 새 리프레시 토큰도 남아 있으면 안 된다: 같은 계정으로 다시 로그인은 되지만 이전 토큰들은 모두 죽었다
    });

    test('다시 로그인하고 계정 삭제(DELETE /me)까지 된다', () async {
      final again = LiveApp.create();
      addTearDown(again.dispose);
      await again.auth.signInWithPassword(username, password);
      expect(again.authStatus, AuthStatus.signedIn);
      await again.auth.deleteAccount();
      expect(again.authStatus, AuthStatus.signedOut);
      final check = LiveApp.create();
      addTearDown(check.dispose);
      await expectLater(
        check.auth.signInWithPassword(username, password),
        throwsA(isA<AuthFailure>().having((f) => f.kind, 'kind', AuthFailureKind.badCredentials)),
      );
    });
  });
}
