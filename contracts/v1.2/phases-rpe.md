# v1.2 2차 — 기간·단계(PRG-17)와 RPE 목표 하중(PRG-19)

2026-11-28 작성. 근거: `templates/TEMPLATE-PLAN.md` R3·R5, `contracts/v1.2/edit.md`, `contracts/v1.1/program-start-ext.md` 99행.
원칙: 모든 새 필드는 선택. 없으면 지금과 똑같이 계산한다(템플릿 회귀 골든이 그대로 통과해야 함). schemaVersion 은 1 그대로(필드 추가만), JSON 스키마 사본 `contracts/v1.2/program.schema.json` 과 `contracts/v0.3/prompt.md`(AI 안내)도 갱신한다.

## 1. 단계(phases)

```json
"phases": [
  {"key": "hyp", "name": "근비대", "weeks": 4, "days": ["A", "B"]},
  {"key": "str", "name": "근력",   "weeks": 3, "days": ["C", "D"]}
]
```
- `days` 는 최상위 `days[].key` 를 가리킨다(같은 날을 여러 단계가 써도 됨). 날 정의는 최상위에 그대로 둔다
- phases 가 있으면 최상위 `cycleWeeks` 는 쓰지 않는다(검증기가 같이 오면 400). 각 단계의 `weeks` 가 그 단계의 주 수
- 단계 안에서 날은 그 단계 `days` 순서로 돈다. 한 바퀴 = 한 주. `state.week` 는 단계 안 주(1부터), 단계가 바뀌면 1로. `weekly[]` 덮어쓰기도 단계 안 주로 고른다
- 단계 끝 = 기존 cycleEnd 처리(CYCLE 규칙 증량, CUSTOM CYCLE_END 반영)를 한 번 하고 다음 단계로
- 상태(ProgramState)에 `phase`(0부터, 기본 0이면 직렬화 생략), `weeksDone`(지난 주 수 합계, 기간 계산용), `finished`(기본 false 생략)

## 2. 끝 동작(onEnd)과 기간(durationWeeks)

정의 최상위(선택):
```json
"durationWeeks": 12,
"onEnd": {"type": "REPEAT"}            // 또는 FINISH, 또는
"onEnd": {"type": "NEXT_PROGRAM", "programId": "<uuid>", "carryTm": true}
```
- 끝나는 시점: phases 가 있으면 마지막 단계 끝, 없으면 `durationWeeks` 주가 지났을 때. 둘 다 없으면 끝나지 않음(지금처럼). phases 와 durationWeeks 는 같이 올 수 없다(400)
- 기본 onEnd: phases 가 있으면 `REPEAT`(다시 1단계, cycle+1), durationWeeks 만 있으면 `FINISH`
- `REPEAT`: phase=0, week=1, cycle+1, weeksDone 은 계속 늘어남
- `FINISH`: state.finished=true, plan() 은 빈 목록. 서버는 그 인스턴스를 `FINISHED` 로 바꾸고 `finishedAt` 기록
- `NEXT_PROGRAM`: FINISH 처리 + 같은 사용자의 대상 프로그램(내 프로그램 또는 템플릿)으로 새 인스턴스를 만든다. 시작일 = 마지막 회차 다음 날(사용자 tz), skipPolicy·weekdays 는 대상 정의 기본. carryTm=true 면 대상의 TM·working 키 중 같은 종목 id 를 쓰는 키에 끝난 인스턴스 값을 넘기고, 나머지 필요 입력은 기존 시작 제안(PRG-14)으로 채운다. 대상이 없거나 입력을 못 채우면 FINISH 만 하고 인스턴스에 `nextError` 를 남긴다
- 끝 처리는 회차를 반영하는 서버 경로(동기화 push 로 세션 완료, skip) 안에서, 사용자 lockUser 아래 한 트랜잭션. 재생(replay)으로 다시 계산해도 두 번 만들지 않는다(이전 인스턴스 id 로 멱등)
- DB V9: `program_instance.finished_at timestamptz NULL`, `previous_instance_id uuid NULL REFERENCES program_instance(id) ON DELETE SET NULL`, `next_error text NULL`

### 시작 때 바꾸기
`StartInstance`·`PreviewRequest`·MCP `start_program`·import `startPrograms` 에 선택 필드 `durationWeeks`(1~104, phases 있는 정의엔 400) 와 `onEnd`. weekdays 처럼 인스턴스 정의 사본에만 넣는다.

### 응답 추가
`Instance`: `phase` = `{"index":0,"key":"hyp","name":"근비대","week":2,"weeks":4,"count":2}` (phases 없으면 null), `weeksDone`, `totalWeeks`(끝이 있으면 전체 주, 없으면 null), `finishedAt`, `previousInstanceId`, `nextInstanceId`(이 인스턴스 뒤로 만들어진 것), `nextError`. `PlannedWorkout`·`PreviewWorkout` 에 `phaseKey`·`phaseName`(phases 있을 때). `ProgramSummary` 에 `totalWeeks`(정의만으로 정해지면)·`phaseCount`.

## 3. RPE 목표 하중

```json
{"count": 1, "reps": 5, "load": {"type": "RPE", "rpe": 8, "of": "squat"}}
{"count": 3, "reps": 5, "load": {"type": "RPE", "rir": 3}}
```
- `rpe`(6~10, 0.5 단위) 또는 `rir`(0~4) 둘 중 하나. rir 은 rpe = 10 − rir 로 계산
- 무게 = 기준 1RM × 표 비율(reps, rpe), 기존 roundWeight(roundingKg 가까운 값, 바벨이면 빈 봉 이상) 그대로
- 기준 1RM 은 새 상태 맵 `e1rm[liftKey]`. `of` 가 있으면 그 키의 e1rm. 필요 입력 종류 `Needs.E1RM`('기준 1RM') 이 생긴다 — requiredInputs 에 RPE 하중을 쓰는 키가 E1RM 으로 나온다(그 키를 다른 하중도 쓰면 TM/WORKING 과 E1RM 을 둘 다 요구). 시작·preview·adjust·정의 교체·swap 요청에 `e1rm` 맵 추가, 응답 `inputs`·`InstanceState` 에도 `e1rm`
- 시작 제안(PRG-14 suggest): E1RM 키는 그 종목 현재 1RM(body-strength.md 3절 우선순위) 그대로(TM 비율 곱하지 않음)
- 표: RPE 10 기준 비율 pct10(r) — r=1..12: 1.000, 0.955, 0.922, 0.892, 0.863, 0.837, 0.811, 0.786, 0.762, 0.739, 0.707, 0.680. r>12 는 1/(1+r/30). pct(reps, rpe) = pct10(reps + (10 − rpe)), 0.5 칸은 이웃 두 값 평균(선형 보간). 엔진 `RpeTable` 한 곳에 두고 앱에는 내리지 않는다(서버 계산 원칙)
- 계획 세트 `PlannedSet.targetRpe`(RPE 하중이면 숫자, 아니면 생략)
- 기록 반영(COMPLETED): RPE 하중 세트를 가진 키마다, 그 회차에서 그 키의 RPE 하중 세트 중 기록된 무게·횟수가 있는 첫 세트(탑 세트)로 e1rm 을 갱신: 새 e1rm = weight ÷ pct(reps, 기록 RPE ?: 목표 RPE). 기록 RPE 는 세트의 rpe, 없고 rir 만 있으면 10 − rir. reps 0 이거나 12 초과면 갱신 안 함. 결과는 0.5kg 반올림. PerformedSet 에 `rpe: Double?` 추가(Replay 가 workout_set.rpe·rir 로 채움)
- RPE 하중 세트는 성공·실패 판정과 연속 실패·디로드에서 빼고(드롭 세트처럼), 대신 위 e1rm 갱신만 한다. progression 규칙이 그 키에 있어도 무시(검증기가 RPE 하중만 쓰는 키에 규칙이 있으면 400)
- 백오프·N-RM 램프업은 이번 범위 아님(백오프는 낮은 rpe 의 RPE 하중으로 표현)

## 4. 앱

- 맞추기 화면(`program_start_page.dart`·`start_cards.dart`):
  - '기간·단계' 카드: phases 가 있으면 단계 목록(이름·주 수, 합계 N주)과 끝 동작 선택(다시 처음부터 / 끝내기 / 다른 프로그램으로 이어서 → 내 프로그램·템플릿 고르기, 'TM 이어받기' 기본 켬). phases 가 없으면 '계속 진행 | N주 후' 선택(N 스텝퍼 4~52, 기본 계속)과 같은 끝 동작 선택. 요약 한 줄 예: '12주 · 끝나면 다시 처음부터'. 기본값 통과(안 건드리면 아무것도 안 보냄)
  - 'RPE' 카드: E1RM 입력이 있을 때만. 키마다 기준 1RM(제안값·출처 라벨, ±roundingKg), 한 줄 설명 'RPE 8 = 2회 더 할 수 있는 무게예요'. 시작 무게 카드와 같은 부품 재사용
  - preview 요청에 durationWeeks·onEnd·e1rm 포함
- 운동 화면: 계획 세트에 targetRpe 가 있으면 목표 옆에 'RPE 8' 칩, 세트 완료 때 RPE 칩 입력을 그 세트에서는 기본 펼침(값은 선택)
- 프로그램 탭·홈 카드: phase 가 있으면 '근비대 2/4주', totalWeeks 가 있으면 '5/12주' 진행 표시. FINISHED 인스턴스는 '진행 중' 목록에서 빠지고 '끝난 프로그램' 접힌 구역(내 프로그램 탭 아래)에 결과 요약(기간, 회차 수, 시작→끝 TM·e1RM) 과 nextInstanceId 가 있으면 '이어진 프로그램' 링크, nextError 면 안내 한 줄
- 편집기(`features/program_editor`): 세트 하중 종류에 'RPE' 추가(rpe/rir 입력), 정의 '기간' 항목(계속 / N주 + 끝 동작). 단계 편집은 이번에 목록 보기만(편집은 JSON·AI) — 단계가 있는 정의를 편집기로 열면 단계 구역을 읽기 전용으로 보여 주고 저장 시 그대로 유지
- DTO: Needs 에 E1RM, 모르는 값 무시. 문구는 기존 방식(ARB 또는 editor_text.dart)

## 5. 템플릿

예시 두 개 추가(서버 catalog, 고정 id 다음 번호, level·family·aka·rules·category 필수):
- 단계 예시: '12주 블록 주기화 4일'(근비대 4주 → 근력 4주 → 피킹 3주 → 테스트·디로드 1주, 끝 동작 REPEAT, CYCLE 단계 끝 증량). 근거 `templates/research/periodized.md`
- RPE 예시: 'RPE 상하체 4일'(본운동 탑 세트 RPE 8 × 1 + 백오프 RPE 7 × 3, 보조는 DOUBLE). 근거 `templates/research/periodized.md`·`hypertrophy.md`
이름은 자체 일반 이름, 원 프로그램 이름은 description 끝 '흔히 ○○로 알려진 구성을 참고' 규칙.

## 6. 테스트 기준

엔진: phases 없는 정의 골든 불변, 단계 전환·주 리셋·weekly 단계 안 주, 단계 끝 cycleEnd 1회, REPEAT/FINISH/durationWeeks, RPE 표 값(5회@8 = pct10(7)=0.811), rir 변환, e1rm 갱신(기록 RPE·목표 RPE·rir), RPE 세트 판정 제외, 검증 400 들(phases+cycleWeeks, phases+durationWeeks, 없는 day key, rpe 범위, RPE 전용 키 규칙).
서버: NEXT_PROGRAM 새 인스턴스·TM 이어받기·멱등(재생 두 번), 대상 없음 nextError, 시작 durationWeeks/onEnd, preview, Instance 응답 필드, MCP start_program 새 필드 e2e 케이스.
앱: 카드 기본값 통과(요청에 필드 없음), 선택 시 요청 필드, RPE 칩, 진행 표시, 끝난 프로그램 구역.
