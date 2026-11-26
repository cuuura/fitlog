// B1 소유(로그인 상태에 따른 redirect). 다른 WP의 화면 클래스 이름은 바꾸지 않는다.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/consent_page.dart';
import '../features/auth/login_page.dart';
import '../features/auth/splash_page.dart';
import '../features/exercise_picker/exercise_picker_page.dart';
import '../features/home/home_page.dart';
import '../features/profile/body_weight_page.dart';
import '../features/profile/profile_page.dart';
import '../features/session/active_session_page.dart';
import '../features/session/session_detail_page.dart';
import '../features/settings/settings_page.dart';
import 'auth/auth_controller.dart';
import 'routes.dart';

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
      GoRoute(path: Routes.home, builder: (_, _) => const HomePage()),
      GoRoute(path: Routes.session, builder: (_, _) => const ActiveSessionPage()),
      GoRoute(path: Routes.pickExercise, builder: (_, _) => const ExercisePickerPage()),
      GoRoute(path: '/sessions/:id', builder: (_, s) => SessionDetailPage(sessionId: s.pathParameters['id']!)),
      GoRoute(path: Routes.settings, builder: (_, _) => const SettingsPage()),
      GoRoute(path: Routes.profile, builder: (_, _) => const ProfilePage()),
      GoRoute(path: Routes.body, builder: (_, _) => const BodyWeightPage()),
    ],
  );
});
