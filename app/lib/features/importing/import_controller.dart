// B1 소유. 가져오기 흐름: 입력 → 미리보기 → 충돌 해결 → 저장 → 다음 조각 또는 결과.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/ai_dto.dart';
import '../../core/api/api_client.dart';
import '../../data/providers.dart';
import '../session/session_controller.dart' show deviceTimezoneProvider;
import 'import_logic.dart';

enum ImportStep { input, working, preview, done }

typedef ValidationDetail = ({String path, String message});

class ImportState {
  final ImportStep step;
  final List<Map<String, Object?>> chunks;

  /// 지금 처리 중인 조각(0부터).
  final int index;
  final String? clientName;
  final ImportPreview? preview;

  /// conflictId → 해결. 조각이 바뀌면 비운다.
  final Map<String, Resolution> resolutions;
  final List<ValidationDetail> validationErrors;

  /// 마지막 오류 문구(서버 메시지). networkError면 화면이 네트워크 문구를 쓴다.
  final String? error;
  final bool networkError;
  final bool saving;
  final List<ImportBatch> batches;

  const ImportState({
    this.step = ImportStep.input,
    this.chunks = const [],
    this.index = 0,
    this.clientName,
    this.preview,
    this.resolutions = const {},
    this.validationErrors = const [],
    this.error,
    this.networkError = false,
    this.saving = false,
    this.batches = const [],
  });

  int get total => chunks.length;
  List<Conflict> get conflicts => preview?.conflicts ?? const [];
  bool get allResolved => conflicts.every((c) => resolutions.containsKey(c.conflictId));
  bool get canSave => step == ImportStep.preview && !saving && allResolved;
  ImportBatch? get lastBatch => batches.isEmpty ? null : batches.last;

  ImportState copyWith({
    ImportStep? step,
    List<Map<String, Object?>>? chunks,
    int? index,
    String? clientName,
    ImportPreview? preview,
    Map<String, Resolution>? resolutions,
    List<ValidationDetail>? validationErrors,
    String? error,
    bool? networkError,
    bool? saving,
    List<ImportBatch>? batches,
    bool clearError = false,
  }) => ImportState(
    step: step ?? this.step,
    chunks: chunks ?? this.chunks,
    index: index ?? this.index,
    clientName: clientName ?? this.clientName,
    preview: preview ?? this.preview,
    resolutions: resolutions ?? this.resolutions,
    validationErrors: validationErrors ?? this.validationErrors,
    error: clearError ? null : (error ?? this.error),
    networkError: clearError ? false : (networkError ?? this.networkError),
    saving: saving ?? this.saving,
    batches: batches ?? this.batches,
  );
}

final importControllerProvider = NotifierProvider.autoDispose<ImportController, ImportState>(ImportController.new);

class ImportController extends Notifier<ImportState> {
  @override
  ImportState build() => const ImportState();

  ImportRequest? _request;

  /// 입력 화면으로 돌아간다(입력 텍스트는 화면이 들고 있다).
  void backToInput() {
    state = const ImportState();
  }

  Future<void> start(Map<String, Object?> bundle, String? clientName) async {
    final chunks = splitBundle(bundle);
    state = ImportState(step: ImportStep.working, chunks: chunks, clientName: clientName);
    await _preview();
  }

  Future<ImportRequest> _build() async {
    final tz = await ref.read(deviceTimezoneProvider)();
    return ImportRequest(bundle: state.chunks[state.index], clientName: state.clientName, tz: tz);
  }

  Future<void> _preview() async {
    try {
      final req = await _build();
      _request = req;
      final p = await ref.read(importRepositoryProvider).preview(req);
      state = state.copyWith(step: ImportStep.preview, preview: p, resolutions: const {}, clearError: true);
    } on ApiException catch (e) {
      _fail(e, backToInput: true);
    }
  }

  void _fail(ApiException e, {required bool backToInput}) {
    if (e.code == 'VALIDATION_FAILED') {
      state = state.copyWith(
        step: ImportStep.input,
        validationErrors: e.details.isEmpty ? [(path: e.field ?? '', message: e.message)] : e.details,
        saving: false,
        clearError: true,
      );
      return;
    }
    state = state.copyWith(
      step: backToInput ? ImportStep.input : ImportStep.preview,
      error: e.message,
      networkError: e.isNetwork,
      saving: false,
    );
  }

  void setResolution(String conflictId, Resolution? r) {
    final next = Map<String, Resolution>.of(state.resolutions);
    if (r == null) {
      next.remove(conflictId);
    } else {
      next[conflictId] = r;
    }
    state = state.copyWith(resolutions: next);
  }

  /// 모든 충돌을 SKIP으로. 덮어쓰기 일괄은 없다.
  void skipAll() {
    state = state.copyWith(
      resolutions: {
        ...state.resolutions,
        for (final c in state.conflicts)
          if (c.allowed.contains(ResolutionAction.SKIP)) c.conflictId: const Resolution(ResolutionAction.SKIP),
      },
    );
  }

  Future<void> save() async {
    if (!state.canSave || _request == null) return;
    state = state.copyWith(saving: true, clearError: true);
    try {
      final req = _request!.withResolutions(state.resolutions);
      final out = await ref.read(importRepositoryProvider).submit(req);
      if (!out.saved) {
        // 새 충돌이 생겼다. 이미 고른 해결은 conflictId로 유지된다.
        state = state.copyWith(preview: out.preview, saving: false);
        return;
      }
      final batches = [...state.batches, out.batch!];
      if (state.index + 1 < state.total) {
        state = state.copyWith(step: ImportStep.working, index: state.index + 1, batches: batches, saving: false);
        await _preview();
      } else {
        state = state.copyWith(step: ImportStep.done, batches: batches, saving: false);
      }
    } on ApiException catch (e) {
      _fail(e, backToInput: false);
    }
  }
}
