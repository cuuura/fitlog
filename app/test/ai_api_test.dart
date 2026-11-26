import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fitlog/core/api/ai_dto.dart';
import 'package:fitlog/core/api/api_client.dart';
import 'package:fitlog/core/api/dto.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  final int status;
  final Object body;
  RequestOptions? last;
  _Adapter(this.status, this.body);
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    last = o;
    return ResponseBody.fromString(
      body is String ? body as String : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [body is String ? 'text/csv' : 'application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiClient _client(_Adapter a) => ApiClient(Dio(BaseOptions(baseUrl: 'http://t'))..httpClientAdapter = a);

void main() {
  const req = ImportRequest(bundle: {'schemaVersion': 1}, clientName: 'Claude');

  test('submitImport 409는 충돌 목록으로', () async {
    final a = _Adapter(409, {
      'valid': true,
      'counts': {
        'sessions': {'NEW': 2},
      },
      'conflicts': [
        {
          'conflictId': 'SESSION_OVERLAP:/sessions/0',
          'code': 'SESSION_OVERLAP',
          'path': '/sessions/0',
          'message': '같은 날 세션',
          'allowed': ['SKIP', 'KEEP_BOTH', 'REPLACE'],
        },
      ],
      'unresolved': ['SESSION_OVERLAP:/sessions/0'],
      'error': {'code': 'CONFLICT_UNRESOLVED', 'message': 'x'},
    });
    final r = await _client(a).submitImport(req.withResolutions({'X': const Resolution(ResolutionAction.SKIP)}));
    expect(r.saved, isFalse);
    expect(r.preview!.conflicts.single.code, ConflictCode.SESSION_OVERLAP);
    expect(r.preview!.conflicts.single.allowed, contains(ResolutionAction.REPLACE));
    expect(r.preview!.counts['sessions']!['NEW'], 2);
    final sent = a.last!.data as Map;
    expect(sent['channel'], 'APP_JSON');
    expect((sent['resolutions'] as Map)['X'], {'action': 'SKIP'});
  });

  test('submitImport 201은 묶음', () async {
    final a = _Adapter(201, {
      'id': 'b1',
      'createdAt': '2026-11-26T10:00:00Z',
      'channel': 'APP_JSON',
      'clientName': 'Claude',
      'summary': {'sessions': 3},
    });
    final r = await _client(a).submitImport(req);
    expect(r.batch!.summary['sessions'], 3);
  });

  test('400 VALIDATION_FAILED는 ApiException(details)', () async {
    final a = _Adapter(400, {
      'error': {
        'code': 'VALIDATION_FAILED',
        'message': 'bad',
        'details': [
          {'path': '/sessions/0/startedAt', 'message': 'required'},
        ],
      },
    });
    await expectLater(
      _client(a).submitImport(req),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', 'VALIDATION_FAILED')
            .having((e) => e.details.single.path, 'path', '/sessions/0/startedAt'),
      ),
    );
  });

  test('내보내기 CSV는 원문 문자열', () async {
    final a = _Adapter(200, '﻿date,weight_kg,source\n2026-11-26 09:00,80,MANUAL\n');
    expect(await _client(a).exportCsv(CsvKind.body), startsWith('﻿date'));
    expect(a.last!.queryParameters['kind'], 'body');
  });

  test('v0.3 출처 필드 파싱', () {
    final s = Session.fromJson({
      'id': 's',
      'startedAt': '2026-11-26T10:00:00Z',
      'tz': 'Asia/Seoul',
      'source': 'AI_MCP',
      'importBatchId': 'b1',
    });
    expect(s.isFromAi, isTrue);
    expect(s.importBatchId, 'b1');
    expect(s.toJson().containsKey('importBatchId'), isFalse);
    final m = BodyMeasurement.fromJson({
      'id': 'm',
      'measuredAt': '2026-11-26T10:00:00Z',
      'weightKg': 80,
      'source': 'AI_JSON',
    });
    expect(m.source, MeasurementSource.AI_JSON);
  });
}
