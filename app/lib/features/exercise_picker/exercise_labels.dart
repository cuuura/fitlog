// B2 소유. 부위·유형·종목 이름의 화면 문구.
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../l10n/gen/app_localizations.dart';

String muscleLabel(AppLocalizations l, Muscle m) => switch (m) {
      Muscle.CHEST => l.exerciseMuscleChest,
      Muscle.BACK => l.exerciseMuscleBack,
      Muscle.LATS => l.exerciseMuscleLats,
      Muscle.TRAPS => l.exerciseMuscleTraps,
      Muscle.SHOULDERS => l.exerciseMuscleShoulders,
      Muscle.REAR_DELTS => l.exerciseMuscleRearDelts,
      Muscle.BICEPS => l.exerciseMuscleBiceps,
      Muscle.TRICEPS => l.exerciseMuscleTriceps,
      Muscle.FOREARMS => l.exerciseMuscleForearms,
      Muscle.QUADS => l.exerciseMuscleQuads,
      Muscle.HAMSTRINGS => l.exerciseMuscleHamstrings,
      Muscle.GLUTES => l.exerciseMuscleGlutes,
      Muscle.CALVES => l.exerciseMuscleCalves,
      Muscle.ADDUCTORS => l.exerciseMuscleAdductors,
      Muscle.ABS => l.exerciseMuscleAbs,
      Muscle.OBLIQUES => l.exerciseMuscleObliques,
      Muscle.LOWER_BACK => l.exerciseMuscleLowerBack,
      Muscle.FULL_BODY => l.exerciseMuscleFullBody,
      Muscle.CARDIO => l.exerciseMuscleCardio,
    };

String typeLabel(AppLocalizations l, ExerciseType t) => switch (t) {
      ExerciseType.BARBELL => l.exerciseTypeBarbell,
      ExerciseType.DUMBBELL => l.exerciseTypeDumbbell,
      ExerciseType.MACHINE => l.exerciseTypeMachine,
      ExerciseType.BODYWEIGHT => l.exerciseTypeBodyweight,
      ExerciseType.BAND => l.exerciseTypeBand,
      ExerciseType.CARDIO => l.exerciseTypeCardio,
    };

/// 영어 로케일이면 영문 이름(있을 때), 아니면 한글 이름.
String exerciseDisplayName(BuildContext context, Exercise e) {
  final en = Localizations.localeOf(context).languageCode == 'en';
  return en && (e.nameEn?.isNotEmpty ?? false) ? e.nameEn! : e.nameKo;
}
