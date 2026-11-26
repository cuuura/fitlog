import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/auth/auth_controller.dart';
import '../../l10n/gen/app_localizations.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  bool _busy = false;
  AuthFailureKind? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).signInWithGoogle();
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e.kind);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(AppLocalizations l, AuthFailureKind k) => switch (k) {
        AuthFailureKind.network => l.authErrorNetwork,
        AuthFailureKind.server => l.authErrorServer,
        AuthFailureKind.noIdToken => l.authErrorNoToken,
        AuthFailureKind.other => l.authErrorOther,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l.appTitle,
                      textAlign: TextAlign.center,
                      style: t.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, color: t.colorScheme.primary)),
                  const SizedBox(height: 12),
                  Text(l.authLoginSubtitle, textAlign: TextAlign.center, style: t.textTheme.bodyLarge),
                  const SizedBox(height: 40),
                  FilledButton.icon(
                    onPressed: _busy ? null : _signIn,
                    icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.login),
                    label: Text(l.authSignInGoogle),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_message(l, _error!),
                        key: const Key('loginError'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: t.colorScheme.error)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
