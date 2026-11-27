# v1.1 프로그램 엔진 확장 계약 (PRG-15, PRG-16, PRG-23)

`contracts/v0.2/engine.md`에 **더하는** 계약이다. 새 필드는 모두 선택이라 기존 템플릿·사용자 프로그램·저장된 인스턴스 상태는 그대로 동작해야 한다. `schemaVersion`은 1 그대로. DB 마이그레이션 없음(상태 JSON 형식 그대로, 세트 목표 열 `target_reps_max`·`target_rest_sec`은 V6에 이미 있음).

스키마 전문: `program.schema.json`(이 폴더). 서버 `resources/schemas/program.schema.json`과 같아야 하고, `/v1/public/schema/program.json`이 이 파일을 내보낸다.

## 1. 스키마 추가

| 위치 | 필드 | 뜻 |
| --- | --- | --- |
| `set` | `repsMax` (정수 1~100) | 반복 범위 상한. 있으면 `reps`는 하한. `repsMax >= reps`. `amrap: true`와 같이 쓸 수 없음 |
| `set` | `restSec` (정수 0~3600) | 이 세트 뒤 목표 휴식 |
| `dayExercise` | `restSec` (정수 0~3600) | 이 종목 세트의 기본 휴식(세트 값이 우선) |
| `weekly[]` | `repsMax` | 주차별 상한 덮어쓰기(`reps`와 같은 규칙) |
| `weekly[]` | `count` (정수 1~20) | 그 주 이 세트 정의의 반복 수(`set.count` 대신) |
| `weekly[]` | `addKg` (−500~500) | 그 주 계산 무게에 더하는 kg(반올림 전). 누적이 아니라 기준 무게 대비 |
| `weekly[]` | `skip` (bool) | true면 그 주 이 세트 정의를 계획에서 뺀다. 종목의 세트가 모두 빠지면 그 주 그 종목을 뺀다. 어떤 주에 날의 종목이 모두 빠지면 검증 에러다(검증기가 주차마다 확인) |
| `rule` | `DOUBLE` | 아래 2절 |

검증 추가: `repsMax < reps` → 에러, `amrap && repsMax` → 에러(weekly 적용 후 기준도 같음), `DOUBLE` 규칙 키의 세트에 `PERCENT_TM` 하중 → 에러(작업 무게 기준 규칙).

## 2. DOUBLE 규칙 (더블 프로그레션)

```json
{ "type": "DOUBLE", "incrementKg": 2.5, "failuresBeforeDeload": 3, "deloadPercent": 0.10 }
```
- 기준은 `working[key]`. 판정 세트(워밍업·`accessory: true`·`countsForProgression: false` 제외)의 목표는 `reps`~`repsMax`(`repsMax` 없으면 `reps`~`reps`)
- 회차 판정(apply):
  - **상한 달성**: 판정 세트가 모두 `실제 reps >= repsMax` → `working += incrementKg`, `failStreak = 0`
  - **실패**: 판정 세트 중 하나라도 `실제 reps < reps`(하한) 또는 기록 없음 → `failStreak += 1`, `>= failuresBeforeDeload`면 `working *= (1 - deloadPercent)`, `failStreak = 0`
  - **범위 안**: 그 외 → 무게 유지, `failStreak = 0`
- `plan(count)`의 "모두 성공 가정"에서 DOUBLE 키는 **무게 유지**로 친다(범위 안 가정). 첫 회차만 확정이라는 규칙은 같다
- `BODYWEIGHT`·`NONE` 하중이면 무게 변화는 계획에 영향이 없다(앱이 지난 기록 무게를 채우는 기존 동작). 상한을 채우면 다음 단계로 가라는 표시는 앱 몫(v1.2 사다리)

### 시작 무게 없이 시작
- DOUBLE 규칙 키는 시작 시 `working` 값이 **선택**이다. `requiredInputs`/TM 제안 응답에 `optional: true`로 표시하고, 인스턴스 생성 시 빠져도 400이 아니다
- `working[key]`가 없으면 계획 세트의 `targetWeightKg = null`(앱은 기존처럼 지난 기록 무게를 채우거나 비움)
- 그 키의 첫 완료 회차에서 판정 세트 중 무게가 있는 세트의 **최소 무게**를 `working[key]`로 정한 뒤 위 판정을 적용한다. 무게 있는 세트가 없으면 계속 없음
- replay는 같은 규칙으로 결정적이다

### 다른 규칙과 범위
- 다른 규칙(LINEAR·AMRAP_TABLE·CYCLE·STAGES)에서 세트에 `repsMax`가 있으면 실패 판정은 **하한(`reps`) 미달**이다(engine.md 3절의 "목표 reps"를 하한으로 읽는다). 상한은 표시·기록용

## 3. 계획(PlannedSet) 출력 추가

```json
{ "plannedSetKey": "A.2.0", "targetReps": 8, "targetRepsMax": 12, "targetWeightKg": 40.0, "isAmrap": false, "isWarmup": false, "restSec": 90 }
```
- `targetRepsMax`: 범위 상한, 없으면 생략(null)
- `restSec`: `set.restSec ?? dayExercise.restSec`, 없으면 생략. 앱은 없으면 사용자 기본 휴식(`defaultRestSec`)
- `weekly.count`·`skip`은 펼친 세트 목록에 반영된 상태로 나온다. `plannedSetKey`의 세트 인덱스는 **그 주에 펼친 뒤** 인덱스(기존과 같음)
- `addKg`는 반올림 전에 더하고, 바벨 최소(`barKg`) 규칙은 그 뒤에 적용

## 4. 앱

- 프로그램 회차를 시작할 때 계획 세트의 `targetRepsMax`→`workout_set.targetRepsMax`, `restSec`→`targetRestSec`로 복사(예정 운동 시작과 같은 방식). 휴식 타이머는 이미 `targetRestSec ?? defaultRestSec`
- 범위 표시는 기존 `8~12` 표기 재사용(현재 세트 패널·세트 표·인스턴스 상세·세션 편집)
- 미달 판정(`plan_logic.dart`)은 하한 기준 그대로
- 시작 화면: `optional: true` 키는 입력칸을 비워둘 수 있고 "비워두면 첫 운동 기록으로 정합니다" 안내. 빈 값은 보내지 않는다

## 5. AI·MCP·가져오기

- `contracts/v0.3/prompt.md`의 프로그램 작성 안내에 `repsMax`·`DOUBLE`·`restSec`·`weekly.count/addKg/skip` 예시 추가
- MCP 도구 입력 스키마는 `program.schema.json`을 가리키므로 도구 추가 없음. e2e에 DOUBLE 규칙 프로그램을 `create_program`→`start_program`(working 생략)→세션 기록→`get_program_plan`(무게 확정) 하는 케이스 1개 추가

## 6. 테스트 벡터 (서버 필수)

| # | 상황 | 기대 |
| --- | --- | --- |
| 1 | DOUBLE 3x8~12 working 40, 12/12/12 | 다음 working 42.5 |
| 2 | DOUBLE 같은 조건 12/11/10 | 무게 유지, failStreak 0 |
| 3 | DOUBLE 7/8/8 세 회차 연속 | 3번째 뒤 working 36.0 |
| 4 | DOUBLE working 없이 시작, 첫 회차 42.5/40/40 × 10회 | working 40 확정 후 판정(범위 안) → 40 |
| 5 | DOUBLE working 없이 시작 | 첫 계획 `targetWeightKg` null, 인스턴스 생성 201 |
| 6 | LINEAR 세트 reps 5 repsMax 8, 실제 6 | 성공(하한 기준) |
| 7 | weekly count [5,4,3] | 주차별 펼친 세트 수 5/4/3, plannedSetKey 인덱스 연속 |
| 8 | weekly addKg [0,5,10], PERCENT_TM 0.7 × TM 100 | 70 / 75 / 80 |
| 9 | weekly skip 4주차(5/3/1 보조) | 4주차 계획에 그 세트 없음, 판정 영향 없음 |
| 10 | restSec 세트 60·종목 120 | 세트 값 60 우선, 없는 세트는 120 |
| 11 | 기존 13종 템플릿 replay·계획 | 변경 전과 같은 결과(회귀) |
| 12 | 검증: repsMax < reps, amrap+repsMax, DOUBLE+PERCENT_TM | 각각 에러 경로 반환 |

## 7. 작업 분할 (Opus 리드 1 + Sonnet 3)

| WP | 소유 | 범위 | 완료 기준 |
| --- | --- | --- | --- |
| X1 서버 | `server/.../engine/`, `program/schema/`, `program/instance/`, resources 스키마, `contracts/v0.3/prompt.md`, e2e 케이스 | 1~3·5·6절 | 벡터 12개, 전체 서버 테스트 통과 |
| X2 앱 | `app/lib/core/api/program_dto.dart`, 프로그램 회차 시작 흐름, 시작 화면 optional 입력 | 4절 | 앱 테스트(DTO 왕복, 시작 시 범위·휴식 복사, optional 빈칸 허용) |
| X3 템플릿 2차 | `server/src/main/resources/programs/`, 템플릿 테스트 | X1 뒤. 반복 범위 템플릿 추가 + 5/3/1 변형 디로드 주 보조 `skip` 적용 | 템플릿별 검증·시뮬레이션 |
