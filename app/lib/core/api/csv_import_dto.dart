// ignore_for_file: constant_identifier_names
// B3(v1.2) CSV 가져오기 미리보기 DTO. POST /v1/imports/csv/preview.
import 'ai_dto.dart';

enum CsvFormat { STRONG, HEVY, AUTO }

/// 서버가 건너뛴 줄.
class CsvSkippedRow {
  final int line;
  final String reason;
  const CsvSkippedRow({required this.line, required this.reason});
  factory CsvSkippedRow.fromJson(Map<String, Object?> j) =>
      CsvSkippedRow(line: (j['line'] as num?)?.toInt() ?? 0, reason: j['reason'] as String? ?? '');
}

class CsvSummary {
  final CsvFormat format;
  final int sessions;
  final int sets;
  final int matchedExercises;
  final List<String> newExercises;
  final List<CsvSkippedRow> skippedRows;
  const CsvSummary({
    required this.format,
    required this.sessions,
    required this.sets,
    required this.matchedExercises,
    this.newExercises = const [],
    this.skippedRows = const [],
  });

  factory CsvSummary.fromJson(Map<String, Object?> j) => CsvSummary(
    format: CsvFormat.values.asNameMap()[j['format']] ?? CsvFormat.AUTO,
    sessions: (j['sessions'] as num?)?.toInt() ?? 0,
    sets: (j['sets'] as num?)?.toInt() ?? 0,
    matchedExercises: (j['matchedExercises'] as num?)?.toInt() ?? 0,
    newExercises: [for (final n in (j['newExercises'] as List? ?? const [])) n as String],
    skippedRows: [for (final r in (j['skippedRows'] as List? ?? const [])) CsvSkippedRow.fromJson((r as Map).cast())],
  );
}

/// 확정 단위 한 조각: 기존 가져오기 묶음과 그 미리보기.
class CsvChunk {
  final Map<String, Object?> bundle;
  final ImportPreview preview;
  const CsvChunk({required this.bundle, required this.preview});
  factory CsvChunk.fromJson(Map<String, Object?> j) => CsvChunk(
    bundle: (j['bundle'] as Map).cast<String, Object?>(),
    preview: ImportPreview.fromJson((j['preview'] as Map).cast()),
  );
}

class CsvPreview {
  final CsvSummary csv;
  final List<CsvChunk> chunks;
  const CsvPreview({required this.csv, required this.chunks});
  factory CsvPreview.fromJson(Map<String, Object?> j) => CsvPreview(
    csv: CsvSummary.fromJson((j['csv'] as Map).cast()),
    chunks: [for (final c in (j['chunks'] as List? ?? const [])) CsvChunk.fromJson((c as Map).cast())],
  );

  int get conflictCount => chunks.fold(0, (a, c) => a + c.preview.conflicts.length);
}
