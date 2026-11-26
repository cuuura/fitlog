import 'package:fitlog/features/importing/import_logic.dart';
import 'package:fitlog/features/importing/import_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _session(int i) => {'startedAt': '2026-01-01T00:00:00+09:00', 'n': i};

void main() {
  group('코드 블록 벗기기', () {
    test('```json 표시를 벗긴다', () {
      expect(stripCodeFence('```json\n{"schemaVersion":1}\n```'), '{"schemaVersion":1}');
      expect(stripCodeFence('```\n{"a":1}\n```\n'), '{"a":1}');
    });

    test('앞뒤 설명이 섞여도 블록 안만 쓴다', () {
      expect(stripCodeFence('여기 있어요:\n```json\n{"a":1}\n```\n끝'), '{"a":1}');
    });

    test('닫는 표시가 없으면 표시 줄만 지운다', () {
      expect(stripCodeFence('```json\n{"a":1}'), '{"a":1}');
    });

    test('표시가 없으면 그대로', () {
      expect(stripCodeFence('  {"a":1}  '), '{"a":1}');
    });
  });

  group('파싱', () {
    test('코드 블록 안의 JSON도 파싱', () {
      final r = parseBundle('```json\n{"schemaVersion": 1, "note": "x"}\n```');
      expect(r, isA<BundleParsed>());
      expect((r as BundleParsed).bundle['note'], 'x');
    });

    test('문법 오류는 줄·열을 돌려준다', () {
      final r = parseBundle('{\n  "a": 1,\n  "b": }\n');
      expect(r, isA<BundleParseError>());
      final e = r as BundleParseError;
      expect(e.problem, BundleParseProblem.syntax);
      expect(e.line, 3);
      expect(e.column, greaterThan(0));
    });

    test('빈 입력과 객체 아님', () {
      expect((parseBundle('  ') as BundleParseError).problem, BundleParseProblem.empty);
      expect((parseBundle('[1,2]') as BundleParseError).problem, BundleParseProblem.notObject);
    });
  });

  group('큰 묶음 분할', () {
    test('한도 안이면 원본 하나', () {
      final b = {'schemaVersion': 1, 'sessions': [for (var i = 0; i < 200; i++) _session(i)]};
      final out = splitBundle(b);
      expect(out, hasLength(1));
      expect(identical(out.single, b), isTrue);
    });

    test('450세션은 200+200+50 세 조각, 첫 조각에만 종목·프로그램·체중', () {
      final b = {
        'schemaVersion': 1,
        'note': '내보내기',
        'exercises': [
          {'nameKo': 'A'},
        ],
        'programs': [
          {'definition': {}},
        ],
        'startPrograms': [
          {'program': {}},
        ],
        'bodyMeasurements': [
          {'weightKg': 70},
        ],
        'sessions': [for (var i = 0; i < 450; i++) _session(i)],
      };
      final out = splitBundle(b);
      expect(out, hasLength(3));
      expect([for (final c in out) (c['sessions'] as List).length], [200, 200, 50]);
      expect(out[0].keys, containsAll(['exercises', 'programs', 'startPrograms', 'bodyMeasurements', 'note']));
      for (final c in out.skip(1)) {
        expect(c.keys.toSet(), {'schemaVersion', 'sessions'});
      }
      // 순서 유지
      expect(((out[2]['sessions'] as List).first as Map)['n'], 400);
    });

    test('체중 1,500개는 첫 조각 1,000 + 체중만 있는 조각 500', () {
      final b = {
        'schemaVersion': 1,
        'bodyMeasurements': [for (var i = 0; i < 1500; i++) {'n': i}],
        'sessions': [for (var i = 0; i < 10; i++) _session(i)],
      };
      final out = splitBundle(b);
      expect(out, hasLength(2));
      expect((out[0]['bodyMeasurements'] as List), hasLength(1000));
      expect((out[0]['sessions'] as List), hasLength(10));
      expect(out[1].keys.toSet(), {'schemaVersion', 'bodyMeasurements'});
      expect((out[1]['bodyMeasurements'] as List), hasLength(500));
    });
  });

  test('프롬프트 자리표시자를 모두 채운다', () {
    final p = buildImportPrompt(
      schemaUrl: 'https://x/import.json',
      programSchemaUrl: 'https://x/program.json',
      today: '2026-11-26',
      tz: 'Asia/Seoul',
      unit: 'lb',
    );
    expect(p, contains('형식: https://x/import.json 의 JSON Schema'));
    expect(p, contains('프로그램 정의는 https://x/program.json.'));
    expect(p, contains('내 표시 단위는 lb이지만'));
    expect(p, contains('내 시간대는 Asia/Seoul, 오늘은 2026-11-26.'));
    expect(p, isNot(contains('{SCHEMA_URL}')));
    expect(p, isNot(contains('{TZ}')));
    expect(p, contains('{"name": "벤치프레스"}'));
    expect(p.trimRight().endsWith('내 요청:'), isTrue);
  });
}
