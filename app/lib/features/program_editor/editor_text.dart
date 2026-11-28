// 프로그램 편집기 화면 문구(한국어). 공통 버튼(저장·취소·추가·삭제)은 앱 공용 문구를 쓴다.
import 'program_definition.dart';

abstract final class ET {
  static const titleNew = '프로그램 만들기';
  static const titleEdit = '프로그램 편집';
  static const titleCopy = '복사해서 고치기';
  static const titleInstance = '이 진행만 고치기';
  static const instanceNote = '이 진행에만 적용돼요. 원래 프로그램은 바뀌지 않아요.';
  static const copySuffix = ' (내 버전)';

  static const basicInfo = '기본 정보';
  static const name = '이름';
  static const description = '설명';
  static const rounding = '무게 단위(반올림)';
  static const barKg = '빈 봉 무게';
  static const tmPercent = '1RM 대비 TM 비율';
  static const cycleWeeks = '사이클 주 수';
  static const cycleWeeksHelp = '비우면 주 단위로 반복하지 않아요';

  static const days = '운동 날';
  static const addDay = '날 추가';
  static const dayName = '날 이름';
  static const weekday = '요일';
  static const weekdayNone = '정하지 않음';
  static const dayDelete = '날 삭제';
  static const dayDeleted = '날을 지웠어요';
  static const dayNew = '새 날';
  static String dayLine(int exercises) => '종목 $exercises개';
  static const noExercises = '아직 종목이 없어요';

  static const addExercise = '종목 추가';
  static const exerciseSettings = '종목 설정';
  static const exerciseSwap = '종목 바꾸기';
  static const exerciseDelete = '종목 삭제';
  static const exerciseDeleted = '종목을 지웠어요';
  static const liftKey = '종목 키';
  static const liftKeyNew = '새 키로 분리';
  static const liftKeyHelp = '같은 키끼리 무게와 증량 규칙을 함께 써요';
  static const accessory = '보조 운동';
  static const accessoryHelp = '증량·실패 판정에서 빼요';
  static const countsForProgression = '증량 판정에 포함';
  static const superset = '슈퍼세트 글자';
  static const supersetHelp = '같은 글자끼리 번갈아 해요(예: A)';
  static const restSec = '휴식(초)';
  static const restSecExercise = '기본 휴식(초)';

  static const addSet = '세트 추가';
  static const setNew = '세트 추가';
  static const setEdit = '세트 수정';
  static const setDuplicate = '복제';
  static const setDelete = '삭제';
  static const setDeleted = '세트를 지웠어요';
  static const count = '세트 수';
  static const reps = '횟수';
  static const repsMax = '최대 횟수';
  static const repsMaxHelp = '범위로 할 때만 적어요(예: 8~12)';
  static const loadType = '무게';
  static const loadValuePercent = '비율';
  static const loadValueKg = '무게(kg)';
  static const amrap = 'AMRAP(최대 반복)';
  static const warmup = '워밍업';
  static const drop = '드롭 세트';
  static const weeklyKept = '주차별 설정 있음(그대로 유지)';

  static const rules = '증량 규칙';
  static const rulesHelp = '종목 키마다 정해요. 없으면 무게를 직접 올려요.';
  static const noLifts = '종목을 추가하면 여기에 나와요';
  static const ruleType = '규칙 종류';
  static const incrementKg = '올리는 무게(kg)';
  static const failuresBeforeDeload = '몇 번 실패하면 낮출지';
  static const deloadPercent = '낮출 비율';
  static const stages = '단계';
  static const stageSets = '세트';
  static const stageReps = '횟수';
  static const stageLastAmrap = '마지막 AMRAP';
  static const addRow = '줄 추가';
  static const table = '횟수별 증량 표';
  static const minReps = '최소 횟수';
  static const maxReps = '최대 횟수';
  static const amountKg = '올릴 kg';
  static const applyAt = '반영 시점';
  static const target = '바꿀 값';
  static const success = '성공했을 때';
  static const failure = '실패했을 때';
  static const failureOn = '실패 규칙 쓰기';
  static const when = '판정';
  static const afterConsecutive = '연속 횟수';
  static const method = '방법';
  static const amount = '값';
  static const steps = 'AMRAP 횟수별 증량 표';

  static const save = '저장';
  static const saving = '저장하는 중';
  static const fixErrors = '고칠 곳이 있어요';
  static const noName = '이름을 적어 주세요';
  static const loadFailed = '프로그램을 불러오지 못했어요';
  static const saveFailed = '저장하지 못했어요';

  static String applyConfirmTitle(int n) => '진행 중인 $n개에도 다음 회차부터 적용할까요?';
  static const applyConfirmBody = '지난 기록은 그대로 두고, 다음 회차부터 새 내용으로 계산해요.';
  static const applyConfirm = '적용';
  static const applySkip = '안 함';
  static const missingTitle = '시작 무게를 알려 주세요';
  static const missingBody = '새로 생긴 종목이라 시작 무게가 필요해요.';
  static const missingTm = 'TM(kg)';
  static const missingWorking = '작업 무게(kg)';
  static const missingInvalid = '숫자로 적어 주세요';
  static const applyDone = '진행 중인 프로그램에도 적용했어요';
  static const applyPartial = '일부는 적용하지 못했어요';

  static String weekdayName(String? w) => switch (w) {
    'MON' => '월',
    'TUE' => '화',
    'WED' => '수',
    'THU' => '목',
    'FRI' => '금',
    'SAT' => '토',
    'SUN' => '일',
    _ => weekdayNone,
  };

  static const loadTypeNames = {
    'PERCENT_TM': 'TM의 몇 %',
    'WORKING': '작업 무게',
    'FIXED': '정해진 무게',
    'BODYWEIGHT': '맨몸',
    'NONE': '직접 정함',
  };

  static const ruleTypeNames = {
    'NONE': '없음',
    'LINEAR': '매번 조금씩(LINEAR)',
    'DOUBLE': '횟수 채우면 증량(DOUBLE)',
    'STAGES': '단계 바꾸기(STAGES)',
    'AMRAP_TABLE': 'AMRAP 표(AMRAP_TABLE)',
    'CYCLE': '사이클마다(CYCLE)',
    'CUSTOM': '직접 정하기(CUSTOM)',
  };

  static const targetNames = {'WORKING': '작업 무게', 'TM': 'TM'};
  static const applyAtNames = {'SESSION': '회차마다', 'WEEK_END': '주 끝', 'CYCLE_END': '사이클 끝'};
  static const applyAtTableNames = {'WEEK_END': '주 끝', 'SESSION': '회차마다'};
  static const successWhenNames = {
    'ALL_SETS': '모든 세트가 목표 횟수 이상',
    'RANGE_TOP': '모든 세트가 최대 횟수 이상',
    'AMRAP_REPS': 'AMRAP 횟수로 표에서 찾기',
  };
  static const successMethodNames = {'ADD_KG': 'kg 더하기', 'ADD_PERCENT': '% 더하기', 'E1RM': '추정 1RM의 비율'};
  static const failureWhenNames = {'ANY_SET': '한 세트라도 목표 미달', 'AMRAP_BELOW': 'AMRAP이 목표 미달'};
  static const failureMethodNames = {'MULTIPLY': '곱하기(낮추기)', 'SUBTRACT_KG': 'kg 빼기', 'NONE': '그대로 두기'};

  static String ruleSummary(Json rule) {
    final t = rule['type'];
    String n(Object? v) => v is num ? (v == v.roundToDouble() ? '${v.toInt()}' : '$v') : '?';
    return switch (t) {
      'LINEAR' || 'DOUBLE' || 'CYCLE' => '${ruleTypeNames[t]} · +${n(rule['incrementKg'])}kg',
      'STAGES' => '${ruleTypeNames[t]} · 단계 ${(rule['stages'] as List?)?.length ?? 0}개',
      'AMRAP_TABLE' => '${ruleTypeNames[t]} · 표 ${(rule['table'] as List?)?.length ?? 0}줄',
      'CUSTOM' => ruleTypeNames['CUSTOM']!,
      _ => ruleTypeNames['NONE']!,
    };
  }
}
