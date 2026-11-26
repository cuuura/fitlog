# 계산 엔진 규칙 (A2 소유)

엔진은 **순수 함수 모듈**이다(DB·HTTP·시계 의존 없음). 이후 로컬 계산으로 옮길 수 있도록 입출력을 데이터로만 주고받는다.

```
plan(program, state, count, settings)            -> List<PlannedWorkout>
apply(program, state, event, settings)             -> State      // event = COMPLETED(세트 결과) | SKIPPED | ADJUSTED(TM·작업 무게 직접 조정)
replay(program, initialState, events)              -> State      // 처음부터 다시 계산(fold)
```

## 1. 상태 (State)

프로그램 인스턴스(진행 중인 프로그램 하나)마다 하나. 서버가 JSON으로 저장한다.

| 필드 | 뜻 |
| --- | --- |
| `tm` | `{ 키: kg }` 트레이닝 맥스. `PERCENT_TM` 하중의 기준 |
| `working` | `{ 키: kg }` 작업 무게. `WORKING` 하중의 기준(5x5, GZCLP, Texas) |
| `stage` | `{ 키: 정수 }` 단계형 규칙의 현재 단계(0부터) |
| `failStreak` | `{ 키: 정수 }` 연속 실패 횟수 |
| `pendingTmDelta` | `{ 키: kg }` 주·사이클 끝에 반영할 TM 증가분 |
| `week` | 현재 주차(1부터, 사이클 안에서) |
| `cycle` | 현재 사이클(1부터) |
| `nextDayIndex` | 다음에 할 `days` 인덱스 |
| `seq` | 지금까지 반영한 회차 수 |

초기 상태는 인스턴스를 만들 때 사용자가 준 `tm`/`working` 값으로 만든다(`openapi.yaml`의 `StartInstance`). 빠진 키는 아래 순서로 제안한다(PRG-14, STA-2):
1. 그 종목의 **가장 최근 측정 1RM**(`one_rm_measurement`), 없으면 2. 최근 90일 세트 중 **최고 추정 1RM**
2. `tm = 1RM × program.tmPercent`(기본 0.90), `working = 1RM × program.workingPercent`(기본 0.80)
3. 둘 다 없으면 사용자가 직접 입력해야 한다(인스턴스 생성 400)

## 2. 하중(load) → 계획 무게

| `load.type` | 무게 |
| --- | --- |
| `PERCENT_TM` | `tm[key] × value` |
| `WORKING` | `working[key] × (value ?? 1.0)` |
| `FIXED` | `kg` |
| `BODYWEIGHT` | 0 (맨몸, `addedWeightKg`로 기록) |
| `NONE` | 무게 없음(보조운동 기본: 지난 기록 무게를 앱이 채움) |

`weekly` 덮어쓰기가 있으면 현재 `week`의 값이 세트 기본값보다 우선한다(5/3/1의 주차별 %).

### 반올림 (PRG-12)
- 계획 무게는 `roundingKg`(프로그램 값, 없으면 2.5) 단위로 **가장 가까운 값**, 동률이면 **내림**. 예: 61.25 → 60.0, 63.75 → 62.5, 63.8 → 65.0
- 바벨 종목은 `barKg`(기본 20) 미만이면 `barKg`
- 반올림은 계획 무게를 만들 때만 한다. `tm`·`working` 자체는 반올림하지 않고 소수 둘째 자리까지 저장한다

## 3. 성공·실패 판정

- 세트 실패 = 실제 `reps` < 목표 `reps`. AMRAP 세트의 목표는 표시된 최소 횟수(`reps`)
- 워밍업 세트와 `accessory: true` 종목은 판정에서 뺀다
- 세트를 아예 기록하지 않음(삭제·미완료) = 실패
- 사용자가 무게를 바꾼 세트(PRG-5): 판정은 **횟수만** 본다. 다음 계획 무게는 규칙 상태(`tm`/`working`)에서 계산하고, 바꾼 무게는 따라가지 않는다
- 종목 판정 = 그 회차에서 그 키의 **판정 대상 세트가 모두 성공**이면 성공

## 4. 증량 규칙 (progression)

`progression[키]`마다 하나. 회차가 끝날 때(`apply`) 처리한다.

### LINEAR (5x5형)
```
성공: working += incrementKg; failStreak = 0
실패: failStreak += 1
      failStreak >= failuresBeforeDeload 이면 working *= (1 - deloadPercent); failStreak = 0
```

### AMRAP_TABLE (nSuns형)
- 그 회차에서 그 키의 `amrapSet`(지정된 세트, 없으면 그 키의 첫 AMRAP 세트)의 실제 횟수로 표를 찾아 `pendingTmDelta[key] += incrementKg`
- `applyAt: WEEK_END`(기본)면 주차가 바뀔 때, `SESSION`이면 바로 `tm`에 더한다
- 표에서 증가분 0이 두 주 연속이면(`failStreak`로 셈) `failuresBeforeDeload` 기준으로 `tm *= (1 - deloadPercent)`

### CYCLE (5/3/1형)
- 사이클이 끝날 때 `tm += incrementKg`
- 그 사이클의 마지막 주(`weekly`의 마지막 주 제외한 AMRAP 주) AMRAP 세트에서 목표 미달이 있으면 그 키는 증가 대신 `tm *= (1 - deloadPercent)`

### STAGES (GZCLP형)
- `stages: [{sets, reps}...]`. 성공이면 `working += incrementKg`, 단계 유지
- 실패면 다음 단계로(`stage += 1`, 무게 유지). 마지막 단계에서 실패하면 `stage = 0`, `working *= (1 - deloadPercent)`
- 계획 세트 수·횟수는 현재 단계 값으로 만든다(세트 정의의 `reps`·`count` 대신)

### NONE
증량 없음(보조운동).

### 디로드 기본값
- `deloadPercent` 기본 0.10, `failuresBeforeDeload` 기본 3 (프로그램이 정하면 그 값)
- 디로드 결과 `working`·`tm`은 반올림하지 않는다. 계획 무게만 반올림

## 5. 일정 (PRG-6, PRG-11, PRG-13)

- `days`를 순서대로 돈다. 마지막 날 다음은 0번이며, 이때 `week += 1`
- `cycleWeeks`가 있으면 `week > cycleWeeks`일 때 `week = 1; cycle += 1`, 그리고 `CYCLE` 규칙 처리(PRG-11 사이클 진행)
- `WEEK_END` 처리 시점 = `week`가 바뀌는 순간
- 건너뛰기(`skipPolicy`, 인스턴스마다 사용자가 고름)
  - `SHIFT`(기본): 건너뛴 날은 없는 것으로 친다. 다음 회차는 같은 날이다. 상태 변화 없음
  - `FIXED_DATE`: `days[].weekday`가 있는 프로그램만 가능. 건너뛴 날은 `skipped`로 남기고 다음 날로 넘어간다. 증량 규칙은 그 날을 **판정하지 않는다**(실패로 세지 않음). 지난 예정일에 세션이 없으면 서버가 자동으로 skip 이벤트를 만든다
  - 두 방식 모두 skip은 명시적 이벤트(`program_skip`)로 남겨 replay에 들어간다
- 여러 인스턴스는 상태를 공유하지 않는다. 같은 종목이 두 프로그램에 있어도 각자 계산

## 6. 재계산 (LOG-10)

- 서버는 상태를 **캐시**로만 믿는다. 진실은 `initialState` + 그 인스턴스에 연결된 끝난 세션(`ended_at` 있음, 삭제 안 됨)과 건너뛰기 기록을 `plan_seq` 순서로 `replay`한 결과다
- 연결된 세션이 바뀌거나(세트 수정·삭제 포함) 삭제·건너뛰기가 생기면 그 인스턴스를 처음부터 `replay`한다(하루 몇 회차라 비용은 무시)
- 같은 입력이면 항상 같은 결과(결정적). 시각·난수 사용 금지

## 7. 계획(PlannedWorkout) 출력

```json
{ "planSeq": 13, "dayIndex": 0, "dayKey": "A", "dayName": "Workout A", "week": 3, "cycle": 1,
  "exercises": [ { "key": "squat", "exerciseId": "019b76da-...-0001", "accessory": false,
     "sets": [ { "plannedSetKey": "A.0.0", "targetReps": 5, "targetWeightKg": 100.0, "isAmrap": false, "isWarmup": false } ] } ] }
```
- `plannedSetKey` = `"{dayKey}.{exerciseIndex}.{setIndex}"`. 세트 기록과 계획을 잇는 키
- `plan(count)`는 지금 상태에서 앞으로 `count`회차를 **모두 성공한다고 가정**하고 만든다. 첫 회차만 확정이고 나머지는 앱의 오프라인 대비용 예상치다

## 8. 테스트 벡터 (A2 필수)

| # | 상황 | 기대 |
| --- | --- | --- |
| 1 | 반올림 61.25 / 63.75 / 63.8 / 18.0(바벨) | 60.0 / 62.5 / 65.0 / 20.0 |
| 2 | 5x5 스쿼트 working 100, 5x5 모두 성공 | 다음 working 102.5 |
| 3 | 5x5 스쿼트 working 100, 3회 연속 실패(5,5,5,5,4) | 3번째 실패 뒤 working 90.0, 계획 90.0 |
| 4 | 5x5 데드리프트(1x5, incrementKg 5) 성공 | +5 |
| 5 | nSuns 벤치 TM 100, 1+ 세트 4회 | 그 주 끝에 TM 102.5(표: 0–1→0, 2–3→2.5, 4–5→2.5, 6+→5) |
| 6 | nSuns 벤치 TM 100, 1+ 세트 7회 | 그 주 끝에 TM 105 |
| 7 | nSuns 같은 주에 TM 증가분이 생겨도 그 주 남은 날 계획 무게는 그대로 | `WEEK_END` 확인 |
| 8 | 사용자가 계획 100kg 세트를 90kg로 바꿔 5회 성공 | 판정 성공, 다음 계획은 규칙대로 102.5 |
| 9 | `SHIFT`로 하루 건너뜀 | 다음 계획이 같은 날·같은 무게 |
| 10 | `FIXED_DATE`로 하루 건너뜀 | 다음 날로 넘어가고 failStreak 변화 없음 |
| 11 | 지난 세션 세트 횟수를 5→3으로 수정 | `replay` 결과 working이 수정 반영 값과 같음 |
| 12 | GZCLP T1 5x3 실패 → 6x2 → 10x1 실패 | 단계 1→2, 마지막 실패 뒤 stage 0, working×0.9 |
| 13 | 4주 시뮬레이션: 5x5(A/B 교대 주 3회, 전부 성공) | 스쿼트 12회 연속 +2.5 → 시작+30.0 |
| 14 | 4주 시뮬레이션: nSuns 4일(1+ 세트 매번 5회) | 각 메인 종목 TM이 주마다 +2.5(하체 +5: 템플릿 표 기준) |

## 9. 1RM 추정식 (STA-6)

| 값 | 식(w=무게, r=횟수, 1≤r≤10) |
| --- | --- |
| EPLEY(기본) | w × (1 + r/30), r=1이면 w |
| BRZYCKI | w × 36 / (37 − r) |
| LOMBARDI | w × r^0.10 |

워밍업 세트, 10회 초과 세트, 무게 없는 세트는 추정에서 뺀다.
