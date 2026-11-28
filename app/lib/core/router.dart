// B1 소유(로그인 상태에 따른 redirect). 다른 WP의 화면 클래스 이름은 바꾸지 않는다.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/consent_page.dart';
import '../features/auth/login_page.dart';
import '../features/auth/splash_page.dart';
import '../features/ai_connect/ai_connect_page.dart';
import '../features/ai_connect/ai_hub_page.dart';
import '../features/ai_history/ai_history_detail_page.dart';
import '../features/ai_history/ai_history_page.dart';
import '../features/deletion_requests/deletion_requests_page.dart';
import '../features/exercise_picker/exercise_picker_page.dart';
import '../features/export/export_page.dart';
import '../features/csv_import/csv_import_page.dart';
import '../features/importing/import_page.dart';
import '../features/history/history_page.dart';
import '../features/history/session_edit_page.dart';
import '../features/me/me_page.dart';
import '../features/shell/app_shell.dart';
import '../features/program_editor/program_editor_page.dart';
import '../features/programs/instance_detail_page.dart';
import '../features/programs/program_detail_page.dart';
import '../features/programs/program_start_page.dart';
import '../features/programs/programs_page.dart';
import '../features/records/exercise_records_page.dart';
import '../features/scheduled/scheduled_edit_page.dart';
import '../features/scheduled/scheduled_list_page.dart';
import '../features/session/session_summary_page.dart';
import '../features/home/home_page.dart';
import '../features/profile/body_weight_page.dart';
import '../features/profile/profile_page.dart';
import '../features/session/active_session_page.dart';
import '../features/session/session_detail_page.dart';
import '../features/settings/settings_page.dart';
import 'auth/auth_controller.dart';
import 'routes.dart';
import '../features/progress/exercise_progress_page.dart';
import '../features/progress/session_comparison_page.dart';

/// 로그인 상태에 따른 이동. null이면 그대로 둔다.
String? authRedirect(AuthStatus status, String location) {
  const gate = {Routes.splash, Routes.login, Routes.consent};
  switch (status) {
    case AuthStatus.unknown:
      return location == Routes.splash ? null : Routes.splash;
    case AuthStatus.signedOut:
      return location == Routes.login ? null : Routes.login;
    case AuthStatus.needsConsent:
      return location == Routes.consent ? null : Routes.consent;
    case AuthStatus.signedIn:
      return gate.contains(location) ? Routes.home : null;
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ValueNotifier<AuthStatus>(ref.read(authControllerProvider));
  ref.listen<AuthStatus>(authControllerProvider, (_, next) => auth.value = next);
  ref.onDispose(auth.dispose);
  return GoRouter(
    initialLocation: Routes.home,
    refreshListenable: auth,
    redirect: (context, state) => authRedirect(auth.value, state.uri.path),
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashPage()),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginPage()),
      GoRoute(path: Routes.consent, builder: (_, _) => const ConsentPage()),
      GoRoute(path: Routes.session, builder: (_, _) => const ActiveSessionPage()),
      GoRoute(path: Routes.pickExercise, builder: (_, _) => const ExercisePickerPage()),
      // 하단 내비가 보이는 화면들. 하위 화면은 속한 탭 아래에 둔다.
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(navigationShell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: Routes.home, builder: (_, _) => const HomePage()),
            // 하루짜리 예정 운동: 오늘 탭 아래라 하단 내비가 그대로 보인다.
            GoRoute(path: Routes.scheduled, builder: (_, _) => const ScheduledListPage()),
            GoRoute(
              path: Routes.scheduledNew,
              builder: (_, s) => ScheduledEditPage(initialDate: s.uri.queryParameters['date']),
            ),
            GoRoute(
              path: '/scheduled/:id/edit',
              builder: (_, s) => ScheduledEditPage(scheduledId: s.pathParameters['id']!),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: Routes.history, builder: (_, _) => const HistoryPage()),
            GoRoute(path: '/sessions/:id', builder: (_, s) => SessionDetailPage(sessionId: s.pathParameters['id']!)),
            GoRoute(path: '/sessions/:id/edit', builder: (_, s) => SessionEditPage(sessionId: s.pathParameters['id']!)),
            GoRoute(
                path: '/sessions/:id/summary',
                builder: (_, s) => SessionSummaryPage(sessionId: s.pathParameters['id']!)),
            GoRoute(
                path: '/sessions/:id/comparison',
                builder: (_, s) => SessionComparisonPage(sessionId: s.pathParameters['id']!)),
            GoRoute(
                path: '/exercises/:id/records',
                builder: (_, s) => ExerciseRecordsPage(exerciseId: s.pathParameters['id']!)),
            GoRoute(
                path: '/exercises/:id/progress',
                builder: (_, s) => ExerciseProgressPage(exerciseId: s.pathParameters['id']!)),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: Routes.programs, builder: (_, _) => const ProgramsPage()),
            GoRoute(
              path: Routes.programEditor,
              builder: (_, s) => ProgramEditorPage(
                programId: s.uri.queryParameters['programId'],
                copyFromProgramId: s.uri.queryParameters['copyFrom'],
                instanceId: s.uri.queryParameters['instanceId'],
              ),
            ),
            GoRoute(path: '/programs/:id', builder: (_, s) => ProgramDetailPage(programId: s.pathParameters['id']!)),
            GoRoute(
                path: '/programs/:id/start',
                builder: (_, s) => ProgramStartPage(programId: s.pathParameters['id']!)),
            GoRoute(path: '/instances/:id', builder: (_, s) => InstanceDetailPage(instanceId: s.pathParameters['id']!)),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: Routes.me, builder: (_, _) => const MePage()),
            GoRoute(path: Routes.settings, builder: (_, _) => const SettingsPage()),
            GoRoute(path: Routes.profile, builder: (_, _) => const ProfilePage()),
            GoRoute(path: Routes.body, builder: (_, _) => const BodyWeightPage()),
            GoRoute(path: Routes.ai, builder: (_, _) => const AiHubPage()),
            GoRoute(path: Routes.importJson, builder: (_, _) => const ImportPage()),
            GoRoute(path: Routes.aiHistory, builder: (_, _) => const AiHistoryPage()),
            GoRoute(path: '/ai/history/:id', builder: (_, s) => AiHistoryDetailPage(batchId: s.pathParameters['id']!)),
            GoRoute(path: Routes.deletionRequests, builder: (_, _) => const DeletionRequestsPage()),
            GoRoute(path: Routes.aiConnect, builder: (_, _) => const AiConnectPage()),
            GoRoute(path: Routes.export, builder: (_, _) => const ExportPage()),
            GoRoute(path: Routes.csvImport, builder: (_, _) => const CsvImportPage()),
          ]),
        ],
      ),
    ],
  );
});
