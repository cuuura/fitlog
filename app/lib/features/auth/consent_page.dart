import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/dto.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/config.dart';
import '../../l10n/gen/app_localizations.dart';

/// ACC-6: 이용약관·개인정보·건강 데이터 동의(모두 필수).
class ConsentPage extends ConsumerStatefulWidget {
  const ConsentPage({super.key});

  @override
  ConsumerState<ConsentPage> createState() => _ConsentPageState();
}

class _ConsentPageState extends ConsumerState<ConsentPage> {
  static const _kinds = [ConsentKind.TERMS, ConsentKind.PRIVACY, ConsentKind.HEALTH_DATA];
  final _checked = <ConsentKind>{};
  bool _busy = false;
  bool _failed = false;

  bool get _all => _checked.length == _kinds.length;

  String _label(AppLocalizations l, ConsentKind k) => switch (k) {
        ConsentKind.TERMS => l.authConsentTerms,
        ConsentKind.PRIVACY => l.authConsentPrivacy,
        ConsentKind.HEALTH_DATA => l.authConsentHealth,
      };

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await ref.read(authControllerProvider.notifier).acceptConsents(AppConfig.consentVersion);
      // 기록은 됐는데 서버가 여전히 동의를 요구하면(버전 불일치 등) 조용히 머물지 말고 오류를 보인다.
      if (mounted && ref.read(authControllerProvider) == AuthStatus.needsConsent) setState(() => _failed = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showDoc(AppLocalizations l, ConsentKind k) {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(_label(l, k)),
        // TODO: 약관·처리방침 전문 연결.
        content: Text(l.authConsentDocPending),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(l.commonCancel))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.authConsentTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(l.authConsentIntro, style: t.textTheme.bodyLarge),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const Key('consentAll'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(l.authConsentAgreeAll, style: const TextStyle(fontWeight: FontWeight.w600)),
              value: _all,
              onChanged: _busy ? null : (v) => setState(() => v! ? _checked.addAll(_kinds) : _checked.clear()),
            ),
            const Divider(),
            for (final k in _kinds)
              CheckboxListTile(
                key: Key('consent_${k.name}'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(_label(l, k)),
                secondary: TextButton(onPressed: () => _showDoc(l, k), child: Text(l.authConsentView)),
                value: _checked.contains(k),
                onChanged: _busy ? null : (v) => setState(() => v! ? _checked.add(k) : _checked.remove(k)),
              ),
            if (_failed)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(l.authConsentError, key: const Key('consentError'), style: TextStyle(color: t.colorScheme.error)),
              ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('consentContinue'),
              onPressed: _all && !_busy ? _submit : null,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l.authConsentContinue),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : () => ref.read(authControllerProvider.notifier).signOut(),
              child: Text(l.authConsentDecline),
            ),
          ],
        ),
      ),
    );
  }
}
