# v1.2 계약 — 편집·확장

`contracts/v0.2/engine.md`, `contracts/v1.1/program-ext.md`에 **더하는** 계약이다. 새 필드는 모두 선택이라 기존 템플릿·사용자 프로그램·인스턴스·세션은 그대로 동작해야 한다. `schemaVersion`은 1 그대로.

| 파일 | 내용 |
| --- | --- |
| `edit.md` | 전체 계약(엔진 CUSTOM 규칙, 프로그램·인스턴스 편집 API, 종목 교체, 순서 기억, 슈퍼세트·드롭세트, CSV 가져오기, AI 분석 도구, 앱 화면, 작업 분할) |
| `db/V7__v1_2_edit.sql` | DB 변경. 서버 `resources/db/migration`에 같은 파일 |
| `program.schema.json` | v1.1 스키마 + 이번 필드(서버 WP A1이 작성, 서버 resources 사본과 같아야 함) |

범위 밖(다른 스레드): 프로그램 추가 개편 3단계(시작 전 미리 계산, 자동 계산 규칙, 시작 시 요일 바꾸기, 맞추기 화면 기간·보조·RPE 카드). 이 스레드는 그 파일(`program_start_page.dart`, `start_cards.dart`, `program_add_sheet.dart`, 시작 요청의 요일 매핑)을 건드리지 않는다. 추가 시트의 '직접 만들기' 진입 연결도 그쪽이 한다(편집기 진입 함수만 제공).
