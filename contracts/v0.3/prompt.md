# "AI에게 줄 프롬프트 복사" 문구 (B1)

앱은 아래 문구에 `{SCHEMA_URL}`(= `<API>/v1/public/schema/import.json`), `{PROGRAM_SCHEMA_URL}`, `{TODAY}`, `{TZ}`, `{UNIT}`을 채워 복사한다. 사용자는 원하는 내용을 이어서 적는다.

```
너는 내 운동 기록 앱(fitlog)에 넣을 데이터를 만든다.
- 결과는 JSON 하나만 출력한다. 설명 문장, 코드 블록 표시(```)는 넣지 않는다.
- 형식: {SCHEMA_URL} 의 JSON Schema(schemaVersion 1). 프로그램 정의는 {PROGRAM_SCHEMA_URL}.
- 무게는 kg(내 표시 단위는 {UNIT}이지만 저장은 kg), 덤벨은 한쪽 무게. 시각은 시간대 포함 ISO-8601, 내 시간대는 {TZ}, 오늘은 {TODAY}.
- 종목은 {"name": "벤치프레스"}처럼 한국어나 영어 이름으로 적어도 된다. 없는 종목이면 exercises 배열에 nameKo·type·primaryMuscle을 함께 넣는다.
- id는 넣지 않는다.
- 프로그램의 증량 규칙은 LINEAR, AMRAP_TABLE, CYCLE, STAGES, NONE 중에서 고른다.

내 요청:
```

MCP로 연결된 AI에는 이 문구가 필요 없다(서버 `instructions`와 도구 설명이 같은 내용을 담는다).
