# "AI에게 줄 프롬프트 복사" 문구 (B1)

앱은 아래 문구에 `{SCHEMA_URL}`(= `<API>/v1/public/schema/import.json`), `{PROGRAM_SCHEMA_URL}`, `{TODAY}`, `{TZ}`, `{UNIT}`을 채워 복사한다. 사용자는 원하는 내용을 이어서 적는다.

```
너는 내 운동 기록 앱(fitlog)에 넣을 데이터를 만든다.
- 결과는 JSON 하나만 출력한다. 설명 문장, 코드 블록 표시(```)는 넣지 않는다.
- 형식: {SCHEMA_URL} 의 JSON Schema(schemaVersion 1). 프로그램 정의는 {PROGRAM_SCHEMA_URL}.
- 무게는 kg(내 표시 단위는 {UNIT}이지만 저장은 kg), 덤벨은 한쪽 무게. 시각은 시간대 포함 ISO-8601, 내 시간대는 {TZ}, 오늘은 {TODAY}.
- 종목은 {"name": "벤치프레스"}처럼 한국어나 영어 이름으로 적어도 된다. 없는 종목이면 exercises 배열에 nameKo·type·primaryMuscle을 함께 넣는다.
- id는 넣지 않는다.
- 프로그램의 증량 규칙은 LINEAR, AMRAP_TABLE, CYCLE, STAGES, DOUBLE, CUSTOM, NONE 중에서 고른다.
- 반복 범위는 세트에 {"reps": 8, "repsMax": 12}(reps가 하한, AMRAP과는 같이 못 씀). 세트 뒤 휴식은 세트나 종목에 "restSec"(초).
- 더블 프로그레션: {"type": "DOUBLE", "incrementKg": 2.5}. 모든 세트가 repsMax에 닿으면 증량, 하한 미달이면 실패로 센다. 시작 무게는 비워도 된다.
- 주차별로 세트를 바꾸려면 세트의 weekly 배열에 {"count": 4, "addKg": 5, "reps": 5, "repsMax": 8}처럼 쓰고, 그 주에 그 세트를 빼려면 {"skip": true}.
- 사용자 정의 증량(CUSTOM): 기본 규칙이 안 맞을 때만 쓴다. 예) 5x5를 모두 채우면 2.5kg 올리고 3번 연속 실패하면 10% 낮춤:
  {"type": "CUSTOM", "target": "WORKING", "success": {"when": "ALL_SETS", "method": "ADD_KG", "amount": 2.5}, "failure": {"when": "ANY_SET", "afterConsecutive": 3, "method": "MULTIPLY", "amount": 0.9}}
  target은 그 종목 세트의 하중이 PERCENT_TM이면 "TM", WORKING이면 "WORKING". applyAt은 "SESSION"(기본)·"WEEK_END"·"CYCLE_END"(cycleWeeks 필요). success.when은 ALL_SETS·RANGE_TOP·AMRAP_REPS(이때 "steps": [{"minReps": 1, "maxReps": 2, "amount": 0}, {"minReps": 3, "amount": 2.5}] 필수, AMRAP 세트 필요), success.method는 ADD_KG(-50~50)·ADD_PERCENT(0~0.5)·E1RM(0.5~1.0, SESSION만), afterConsecutive는 1~10. failure는 생략하면 실패해도 무게 유지. 성공과 실패가 같이 맞으면 실패가 우선. 워밍업·드롭 세트는 판정에서 빠진다.
- 슈퍼세트는 같은 날 종목의 "superset": "A"(1~8자, 같은 값끼리 묶음). 드롭 세트는 세트에 "drop": true(amrap·warmup과 같이 못 씀, 판정 제외).
- 프로그램을 분석하고 조정할 때(MCP 연결 AI): 먼저 get_program_analysis로 기록을 읽고 어떤 종목이 정체인지 설명한다. 바꿀 내용(어떤 종목의 규칙·세트·종목을 무엇에서 무엇으로)을 내게 먼저 보여 주고 동의를 받는다. 동의한 뒤에만 update_program(내 프로그램 정의 수정)이나 edit_program_instance(진행 중인 프로그램에 다음 회차부터 적용, 종목 교체 포함)를 호출한다. 동의 없이 바꾸지 않는다.

내 요청:
```

MCP로 연결된 AI에는 이 문구가 필요 없다(서버 `instructions`와 도구 설명이 같은 내용을 담는다).
