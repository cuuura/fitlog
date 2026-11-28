// B3(v1.2) 다른 앱(Strong·Hevy) CSV 가져오기. 흐름: 입력 → 미리보기(서버 변환) → 조각별 확정 → 결과.
// 확정은 기존 가져오기 저장소(importRepositoryProvider.submit)를 그대로 쓴다.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/ai_dto.dart';
import '../../core/api/api_client.dart';
import '../../core/api/api_providers.dart';
import '../../core/api/csv_import_dto.dart';
import '../../core/api/dto.dart' show WeightUnit;
import '../../data/providers.dart';
import '../session/session_controller.dart' show deviceTimezoneProvider;

/// 서버 본문 한도(4MB). 넘으면 요청 없이 바로 막는다.
const csvMaxBytes = 4 * 1024 * 1024;

/// 가져오기 이력에 남는 클라이언트 이름.
const csvClientName = 'CSV';

abstract interface class CsvImportRepository {
  Future<CsvPreview> preview({required CsvFormat format, required String csv, WeightUnit? weightUnit, required String tz});
}

class RemoteCsvImportRepository implements CsvImportRepository {
  final ApiClient api;
  RemoteCsvImportRepository(this.api);
  @override
  Future<CsvPreview> preview({required CsvFormat format, required String csv, WeightUnit? weightUnit, required String tz}) =>
      api.previewCsvImport(format: format, csv: csv, weightUnit: weightUnit?.name, tz: tz);
}

final csvImportRepositoryProvider = Provider<CsvImportRepository>(
  (ref) => RemoteCsvImportRepository(ref.watch(apiClientProvider)),
);

enum CsvStep { input, working, preview, confirming, done }

/// 화면이 문구로 바꾸는 오류 종류.
enum CsvErrorKind { tooLarge, badFormat, network, conflict, other }

class CsvError {
  final CsvErrorKind kind;

  /// 서버가 준 문구(badFormat·other일 때 부가 설명).
  final String? detail;
  const CsvError(this.kind, [this.detail]);
}

class CsvImportState {
  final CsvStep step;
  final CsvFormat format;
  final WeightUnit weightUnit;
  final String? fileName;
  final String? csvText;
  final CsvPreview? preview;

  /// 확정 중이거나 실패로 멈춘 조각(0부터).
  final int index;
  final List<ImportBatch> batches;
  final CsvError? error;

  const CsvImportState({
    this.step = CsvStep.input,
    this.format = CsvFormat.AUTO,
    this.weightUnit = WeightUnit.KG,
    this.fileName,
    this.csvText,
    this.preview,
    this.index = 0,
    this.batches = const [],
    this.error,
  });

  int get totalChunks => preview?.chunks.length ?? 0;
  bool get hasFile => csvText != null;
  bool get canPreview => step == CsvStep.input && hasFile;

  /// 일부만 저장되고 멈춘 상태(다시 시도로 이어서 저장한다).
  bool get partiallySaved => step == CsvStep.preview && batches.isNotEmpty;
  bool get canConfirm => step == CsvStep.preview && totalChunks > 0;

  CsvImportState copyWith({
    CsvStep? step,
    CsvFormat? format,
    WeightUnit? weightUnit,
    String? fileName,
    String? csvText,
    CsvPreview? preview,
    int? index,
    List<ImportBatch>? batches,
    CsvError? error,
    bool clearError = false,
    bool clearFile = false,
    bool clearPreview = false,
  }) => CsvImportState(
    step: step ?? this.step,
    format: format ?? this.format,
    weightUnit: weightUnit ?? this.weightUnit,
    fileName: clearFile ? null : (fileName ?? this.fileName),
    csvText: clearFile ? null : (csvText ?? this.csvText),
    preview: clearPreview ? null : (preview ?? this.preview),
    index: index ?? this.index,
    batches: batches ?? this.batches,
    error: clearError ? null : (error ?? this.error),
  );
}

final csvImportControllerProvider = NotifierProvider.autoDispose<CsvImportController, CsvImportState>(
  CsvImportController.new,
);

class CsvImportController extends Notifier<CsvImportState> {
  @override
  CsvImportState build() => const CsvImportState();

  void setFormat(CsvFormat f) => state = state.copyWith(format: f);
  void setWeightUnit(WeightUnit u) => state = state.copyWith(weightUnit: u);

  /// 고른 파일을 들고 있는다. 4MB를 넘으면 오류를 보여 주고 파일은 비운다.
  void setFile(String name, String text, int byteLength) {
    if (byteLength > csvMaxBytes) {
      state = state.copyWith(clearFile: true, error: const CsvError(CsvErrorKind.tooLarge));
      return;
    }
    state = state.copyWith(fileName: name, csvText: text, clearError: true);
  }

  void clearFile() => state = state.copyWith(clearFile: true, clearError: true);

  /// 입력 화면으로 돌아간다(파일·형식은 유지).
  void backToInput() => state = state.copyWith(
    step: CsvStep.input,
    clearPreview: true,
    index: 0,
    batches: const [],
    clearError: true,
  );

  /// 처음부터 다시(파일도 비운다).
  void reset() => state = const CsvImportState();

  Future<void> loadPreview() async {
    final text = state.csvText;
    if (text == null || state.step != CsvStep.input) return;
    state = state.copyWith(step: CsvStep.working, clearError: true);
    try {
      final tz = await ref.read(deviceTimezoneProvider)();
      final p = await ref.read(csvImportRepositoryProvider).preview(
        format: state.format,
        csv: text,
        weightUnit: state.format == CsvFormat.STRONG ? state.weightUnit : null,
        tz: tz,
      );
      state = state.copyWith(step: CsvStep.preview, preview: p, index: 0, batches: const []);
    } catch (e) {
      state = state.copyWith(step: CsvStep.input, error: _classify(e));
    }
  }

  /// 조각을 차례로 확정한다. 실패하면 그 조각에서 멈추고(이미 저장된 조각은 유지) 다시 누르면 이어서 한다.
  /// 겹치는 기록(같은 파일을 다시 가져온 경우 등)은 건너뛰기로 처리한다.
  Future<void> confirm() async {
    final p = state.preview;
    if (p == null || state.step != CsvStep.preview) return;
    state = state.copyWith(step: CsvStep.confirming, clearError: true);
    final repo = ref.read(importRepositoryProvider);
    final tz = await ref.read(deviceTimezoneProvider)();
    var batches = state.batches;
    for (var i = state.index; i < p.chunks.length; i++) {
      if (!ref.mounted) return; // 화면을 떠나 컨트롤러가 사라졌으면 멈춘다(이미 저장된 조각은 이력에서 되돌릴 수 있다).
      state = state.copyWith(index: i);
      final chunk = p.chunks[i];
      try {
        var req = ImportRequest(
          bundle: chunk.bundle,
          clientName: csvClientName,
          tz: tz,
          resolutions: _skipAll(chunk.preview.conflicts),
        );
        var out = await repo.submit(req);
        if (!out.saved) {
          // 미리보기에 없던 새 충돌: 건너뛰기로 한 번 더 시도.
          final more = out.preview!.conflicts;
          req = req.withResolutions({...req.resolutions, ..._skipAll(more)});
          out = await repo.submit(req);
          if (!out.saved) {
            state = state.copyWith(step: CsvStep.preview, batches: batches, error: const CsvError(CsvErrorKind.conflict));
            return;
          }
        }
        batches = [...batches, out.batch!];
        if (!ref.mounted) return;
        state = state.copyWith(batches: batches);
      } catch (e) {
        if (!ref.mounted) return;
        state = state.copyWith(step: CsvStep.preview, batches: batches, error: _classify(e));
        return;
      }
    }
    state = state.copyWith(step: CsvStep.done, index: p.chunks.length, batches: batches);
  }

  static Map<String, Resolution> _skipAll(List<Conflict> conflicts) => {
    for (final c in conflicts)
      if (c.allowed.contains(ResolutionAction.SKIP)) c.conflictId: const Resolution(ResolutionAction.SKIP),
  };

  static CsvError _classify(Object e) {
    if (e is ApiException) {
      if (e.statusCode == 413) return const CsvError(CsvErrorKind.tooLarge);
      if (e.isNetwork) return const CsvError(CsvErrorKind.network);
      if (e.statusCode == 400 || e.code == 'VALIDATION_FAILED') {
        return CsvError(CsvErrorKind.badFormat, e.message.isEmpty ? null : e.message);
      }
      return CsvError(CsvErrorKind.other, e.message.isEmpty ? null : e.message);
    }
    return const CsvError(CsvErrorKind.other);
  }
}
