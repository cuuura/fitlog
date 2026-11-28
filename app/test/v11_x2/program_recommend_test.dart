import 'package:fitlog/core/api/program_dto.dart';
import 'package:fitlog/features/programs/program_recommend.dart';
import 'package:flutter_test/flutter_test.dart';

ProgramSummary _t(String id, String level, int days, {String? family}) =>
    ProgramSummary(
      id: id,
      name: id,
      builtIn: true,
      dayCount: days,
      level: level,
      family: family,
    );

final _all = [
  _t('b3', 'BEGINNER', 3, family: 'w'),
  _t('b3b', 'BEGINNER', 3),
  _t('i3', 'INTERMEDIATE', 3, family: 'w'),
  _t('i4', 'INTERMEDIATE', 4, family: 'n'),
  _t('i5', 'INTERMEDIATE', 5, family: 'n'),
  _t('i6', 'INTERMEDIATE', 6, family: 'n'),
  _t('a4', 'ADVANCED', 4),
  _t('x3', 'MYSTERY', 3),
];

List<String> _ids(Recommendation? r) => [for (final p in r!.programs) p.id];

void main() {
  test('기록이 거의 없으면(주 1회 미만) 입문 + 주 3일', () {
    final r = recommendTemplates(
      templates: _all,
      weeklyAvg: 0.5,
      hasOneRm: true,
    );
    expect(_ids(r), ['b3', 'b3b']);
    expect(r!.reason.kind, RecReasonKind.fresh);
  });

  test('1RM 이 없으면 많이 운동해도 입문', () {
    final r = recommendTemplates(
      templates: _all,
      weeklyAvg: 4,
      hasOneRm: false,
    );
    expect(r!.reason.kind, RecReasonKind.steadyBeginner);
    expect(r.programs.every((p) => p.level == 'BEGINNER'), isTrue);
  });

  test('주 3회 안팎 + 1RM 있음이면 3일 중급이 먼저', () {
    final r = recommendTemplates(
      templates: _all,
      weeklyAvg: 3.2,
      hasOneRm: true,
    );
    expect(r!.reason.kind, RecReasonKind.steady);
    expect(r.reason.perWeek, 3);
    expect(_ids(r).first, 'i3');
  });

  test('주 4회 이상 + 1RM 있음이면 중급 4~5일, 4일 먼저, 같은 묶음은 하나만', () {
    final r = recommendTemplates(
      templates: _all,
      weeklyAvg: 4.4,
      hasOneRm: true,
    );
    expect(r!.reason.kind, RecReasonKind.strong);
    expect(_ids(r).first, 'i4');
    expect(r.programs.where((p) => p.family == 'n').length, 1);
  });

  test('진행 중인 템플릿은 제외하고 상급·모르는 수준은 추천하지 않는다', () {
    final r = recommendTemplates(
      templates: _all,
      weeklyAvg: 4,
      hasOneRm: true,
      runningIds: {'i4'},
    );
    expect(_ids(r), isNot(contains('i4')));
    expect(_ids(r), isNot(contains('a4')));
    expect(_ids(r), isNot(contains('x3')));
  });

  test('후보가 없으면 null', () {
    expect(
      recommendTemplates(
        templates: [_t('a', 'ADVANCED', 4)],
        weeklyAvg: 3,
        hasOneRm: true,
      ),
      isNull,
    );
    expect(
      recommendTemplates(templates: const [], weeklyAvg: 0, hasOneRm: false),
      isNull,
    );
  });
}
