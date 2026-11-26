// B2 소유. 종목 선택 화면의 저장소 호출 모음.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/dto.dart';
import '../../data/providers.dart';

/// 종목 목록이 바뀔 때(내 종목 추가·수정·삭제) 다시 검색하도록 알려주는 스트림.
final allExercisesProvider = StreamProvider<List<Exercise>>((ref) => ref.watch(exerciseRepositoryProvider).watchAll());

class ExerciseController {
  ExerciseController(this._ref);
  final Ref _ref;

  /// v0.1이 제공하는 기록 유형만 돌려준다.
  Future<List<Exercise>> search({String? query, Muscle? muscle, ExerciseType? type}) async {
    final r = await _ref.read(exerciseRepositoryProvider).search(query: query, muscle: muscle, type: type);
    return r.where((e) => v01ExerciseTypes.contains(e.type)).toList();
  }

  Future<Exercise> createCustom(ExerciseInput input) => _ref.read(exerciseRepositoryProvider).createCustom(input);
  Future<Exercise> updateCustom(ExerciseInput input) => _ref.read(exerciseRepositoryProvider).updateCustom(input);
  Future<void> deleteCustom(String id) => _ref.read(exerciseRepositoryProvider).deleteCustom(id);
}

final exerciseControllerProvider = Provider<ExerciseController>((ref) => ExerciseController(ref));
