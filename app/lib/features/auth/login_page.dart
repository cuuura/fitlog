import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/api_providers.dart';
import '../../core/api/dto.dart';
import '../../core/auth/auth_controller.dart';
import '../../l10n/gen/app_localizations.dart';

final _usernameRe = RegExp(r'^[a-zA-Z0-9._-]{3,32}$');

/// 아이디 검증(contracts/v1.0/auth-password.md): 앞뒤 공백 제거 후 3~32자 `[a-zA-Z0-9._-]`.
bool isValidUsername(String v) => _usernameRe.hasMatch(v.trim());

/// 비밀번호 검증: 8~128자.
bool isValidPassword(String v) => v.length >= 8 && v.length <= 128;

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _code = TextEditingController();
  final _displayName = TextEditingController();

  bool _busy = false;
  bool _signup = false;
  bool _obscure = true;
  AuthFailure? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    _code.dispose();
    _displayName.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function(AuthController c) f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f(ref.read(authControllerProvider.notifier));
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() => _run((c) => c.signInWithGoogle());

  Future<void> _submitPassword() async {
    if (_busy || !(_formKey.currentState?.validate() ?? false)) return;
    if (_signup) {
      await _run(
        (c) =>
            c.registerWithPassword(_username.text, _password.text, _code.text.trim(), displayName: _displayName.text),
      );
    } else {
      await _run((c) => c.signInWithPassword(_username.text, _password.text));
    }
  }

  String _message(AppLocalizations l, AuthFailure f) => switch (f.kind) {
    AuthFailureKind.network => l.authErrorNetwork,
    AuthFailureKind.server => l.authErrorServer,
    AuthFailureKind.noIdToken => l.authErrorNoToken,
    AuthFailureKind.other => l.authErrorOther,
    AuthFailureKind.badCredentials => l.authPasswordBadCredentials,
    AuthFailureKind.locked =>
      f.retryAfter == null
          ? l.authPasswordLockedGeneric
          : l.authPasswordLocked(((f.retryAfter!.inSeconds + 59) ~/ 60).clamp(1, 1 << 20)),
    AuthFailureKind.signupCodeWrong => l.authPasswordCodeWrong,
    AuthFailureKind.usernameTaken => l.authPasswordTaken,
    AuthFailureKind.validation => switch (f.field) {
      'username' => l.authPasswordValidationUsername,
      'password' => l.authPasswordValidationPassword,
      _ => l.authPasswordValidation,
    },
  };

  Widget _passwordForm(AppLocalizations l, AuthMethods m) {
    final signup = _signup && m.passwordSignup;
    final toggle = IconButton(
      key: const Key('pwToggle'),
      tooltip: _obscure ? l.authPasswordShow : l.authPasswordHide,
      icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
      onPressed: () => setState(() => _obscure = !_obscure),
    );
    return Form(
      key: _formKey,
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              key: const Key('pwUsername'),
              controller: _username,
              enabled: !_busy,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: [signup ? AutofillHints.newUsername : AutofillHints.username],
              inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
              decoration: InputDecoration(
                labelText: l.authPasswordUsername,
                helperText: signup ? l.authPasswordUsernameHelper : null,
                helperMaxLines: 2,
              ),
              validator: (v) => isValidUsername(v ?? '') ? null : l.authPasswordErrUsername,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('pwPassword'),
              controller: _password,
              enabled: !_busy,
              obscureText: _obscure,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: signup ? TextInputAction.next : TextInputAction.done,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: [signup ? AutofillHints.newPassword : AutofillHints.password],
              onFieldSubmitted: signup ? null : (_) => _submitPassword(),
              decoration: InputDecoration(
                labelText: l.authPasswordPassword,
                helperText: signup ? l.authPasswordPasswordHelper : null,
                helperMaxLines: 2,
                suffixIcon: toggle,
              ),
              validator: (v) => isValidPassword(v ?? '') ? null : l.authPasswordErrPassword,
            ),
            if (signup) ...[
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('pwConfirm'),
                controller: _confirm,
                enabled: !_busy,
                obscureText: _obscure,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(labelText: l.authPasswordConfirm),
                validator: (v) => v == _password.text ? null : l.authPasswordErrMismatch,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('pwCode'),
                controller: _code,
                enabled: !_busy,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(labelText: l.authPasswordSignupCode),
                validator: (v) => (v ?? '').trim().isEmpty ? l.authPasswordErrCode : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('pwDisplayName'),
                controller: _displayName,
                enabled: !_busy,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.nickname],
                decoration: InputDecoration(labelText: l.authPasswordDisplayName),
                onFieldSubmitted: (_) => _submitPassword(),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('pwSubmit'),
              onPressed: _busy ? null : _submitPassword,
              child: Text(signup ? l.authPasswordSignUp : l.authPasswordSignIn),
            ),
            if (m.passwordSignup)
              TextButton(
                key: const Key('pwModeToggle'),
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _signup = !_signup;
                        _error = null;
                        _formKey.currentState?.reset();
                      }),
                child: Text(signup ? l.authPasswordToLogin : l.authPasswordToSignup, textAlign: TextAlign.center),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = Theme.of(context);
    // 조회 중·실패 때는 Google만 보인다(기존 동작 유지).
    final m = ref.watch(authMethodsProvider).value ?? AuthMethods.googleOnly;
    // 둘 다 꺼져 있으면 로그인 수단이 없으므로 Google 버튼을 남긴다.
    final showGoogle = m.google || !m.password;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l.appTitle,
                    textAlign: TextAlign.center,
                    style: t.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: t.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(l.authLoginSubtitle, textAlign: TextAlign.center, style: t.textTheme.bodyLarge),
                  const SizedBox(height: 40),
                  if (showGoogle)
                    FilledButton.icon(
                      key: const Key('googleSignIn'),
                      onPressed: _busy ? null : _signIn,
                      icon: _busy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.login),
                      label: Text(l.authSignInGoogle),
                    ),
                  if (m.password) ...[
                    if (showGoogle) ...[
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          const Expanded(child: Divider()),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(l.authPasswordDivider),
                          ),
                          const Expanded(child: Divider()),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                    _passwordForm(l, m),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _message(l, _error!),
                      key: const Key('loginError'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: t.colorScheme.error),
                    ),
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
