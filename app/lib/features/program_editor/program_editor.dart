// 프로그램 편집기 진입점. 다른 화면은 이 함수로만 편집기를 연다.
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/routes.dart';

export 'program_editor_page.dart' show ProgramEditorPage;

/// 편집기를 연다. 인자 없으면 새로 만들기, [programId]는 내 프로그램 고치기,
/// [copyFromProgramId]는 복사해서 새로 만들기, [instanceId]는 진행 중인 것만 고치기.
Future<void> openProgramEditor(
  BuildContext context, {
  String? programId,
  String? copyFromProgramId,
  String? instanceId,
}) async {
  await context.push<bool>(
    Routes.programEditorFor(programId: programId, copyFromProgramId: copyFromProgramId, instanceId: instanceId),
  );
}
