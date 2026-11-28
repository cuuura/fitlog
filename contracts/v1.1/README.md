# v1.1 계약

| 파일 | 내용 |
| --- | --- |
| `program-ext.md` | 프로그램 엔진 확장: 반복 범위·더블 프로그레션(PRG-15), 주차별 세트 수·kg 가산·제외(PRG-16), 기본 휴식(PRG-23). 작업 분할 X1~X3 |
| `program-start-ext.md` | 프로그램 시작 확장(추가 개편 3단계): 시작 전 미리 계산, 시작할 때 요일 바꾸기, 회당 시간, 자동 계산 규칙(derive)·첫 운동에서 정하기 |
| `program.schema.json` | v0.2 스키마에 위 필드를 더한 전문. 서버 `resources/schemas/program.schema.json`과 같아야 함 |

v0.2 엔진 규칙(`../v0.2/engine.md`)에 더하는 계약이다. 새 필드는 모두 선택이고 schemaVersion은 1 그대로다.
