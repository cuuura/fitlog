// B2 소유. AI-5 삭제 요청 승인·거절(온라인 전용).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/ai_dto.dart';
import '../../core/api/api_client.dart';
import '../../core/clock.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../ai_history/ai_labels.dart';
import '../ai_connect/ai_avatar.dart';
import '../programs/program_common.dart' show ErrorRetry;
import '../session/active_session_page.dart' show confirmDialog;
import 'deletion_providers.dart';

/// 만료까지 남은 시간 문구. 지났으면 "만료됨".
String remainingText(AppLocalizations l, Duration left) {
  if (left <= Duration.zero) return l.deletionExpired;
  final h = left.inHours;
  final m = left.inMinutes % 60;
  final t = h > 0 ? l.deletionDurationHm(h, m) : l.deletionDurationM(left.inMinutes < 1 ? 1 : left.inMinutes);
  return l.deletionExpiresIn(t);
}

class DeletionRequestsPage extends ConsumerStatefulWidget {
  const DeletionRequestsPage({super.key});

  @override
  ConsumerState<DeletionRequestsPage> createState() => _DeletionRequestsPageState();
}

class _DeletionRequestsPageState extends ConsumerState<DeletionRequestsPage> {
  List<DeletionRequest>? _items;
  Object? _error;
  bool _loading = true;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ref.read(deletionRequestRepositoryProvider).list();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _decide(DeletionRequest r, {required bool approve}) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final label = r.label ?? aiEntityLabel(l, r.entity);
    final ok = await confirmDialog(
      context,
      title: approve ? l.deletionApproveTitle : l.deletionRejectTitle,
      body: approve ? l.deletionApproveBody(label) : null,
      confirmLabel: approve ? l.deletionApprove : l.deletionReject,
      confirmKey: Key(approve ? 'deletion-approve-confirm' : 'deletion-reject-confirm'),
    );
    if (!ok || !mounted) return;
    setState(() => _busyId = r.id);
    final repo = ref.read(deletionRequestRepositoryProvider);
    String message;
    try {
      if (approve) {
        await repo.approve(r.id);
        message = l.deletionApproved;
      } else {
        await repo.reject(r.id);
        message = l.deletionRejected;
      }
    } on ApiException catch (e) {
      message = switch (e.statusCode) {
        409 => l.deletionAlreadyDecided,
        410 => l.deletionGone,
        403 => l.deletionForbidden,
        _ => l.deletionFailed,
      };
    } catch (_) {
      message = l.deletionFailed;
    }
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(message)));
    setState(() => _busyId = null);
    ref.invalidate(pendingDeletionCountProvider);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final now = ref.watch(clockProvider)();
    Widget list(bool pending) {
      final items = [
        for (final r in _items ?? const <DeletionRequest>[])
          if ((r.status == DeletionStatus.PENDING) == pending) r,
      ];
      if (items.isEmpty) {
        return Center(
          child: Text(
            pending ? l.deletionEmptyPending : l.deletionEmptyDone,
            key: Key(pending ? 'deletion-empty-pending' : 'deletion-empty-done'),
          ),
        );
      }
      return ListView(
        key: Key(pending ? 'deletion-list-pending' : 'deletion-list-done'),
        padding: const EdgeInsets.all(12),
        children: [
          if (pending) _Sep(l.aiDelSection),
          for (final r in items) _tile(context, l, r, now),
        ],
      );
    }

    Widget body;
    if (_loading && _items == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null && _items == null) {
      body = ErrorRetry(error: _error!, onRetry: _reload);
    } else {
      body = TabBarView(children: [list(true), list(false)]);
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.deletionTitle),
          bottom: TabBar(
            tabs: [
              Tab(key: const Key('deletion-tab-pending'), text: l.deletionTabPending),
              Tab(key: const Key('deletion-tab-done'), text: l.deletionTabDone),
            ],
          ),
        ),
        body: body,
      ),
    );
  }

  Widget _tile(BuildContext context, AppLocalizations l, DeletionRequest r, DateTime now) {
    final theme = Theme.of(context);
    final pending = r.status == DeletionStatus.PENDING;
    final left = r.expiresAt.difference(now);
    final expired = pending && left <= Duration.zero;
    final statusText = switch (r.status) {
      DeletionStatus.PENDING => remainingText(l, left),
      DeletionStatus.APPROVED => l.deletionStatusApproved,
      DeletionStatus.REJECTED => l.deletionStatusRejected,
      DeletionStatus.EXPIRED => l.deletionStatusExpired,
    };
    final c = AppColors.of(context);
    final who = r.clientName;
    final label = r.label ?? aiEntityLabel(l, r.entity);
    // 삭제는 가장 무거운 행동이라 AI 출처(파랑) 카드로 따로 구분하고, 승인은 테두리 버튼으로.
    return Container(
      key: Key('deletion-${r.id}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.aiSoft, borderRadius: BorderRadius.circular(AppRadius.md)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (who != null) ...[AiAvatar(who, size: 28), const SizedBox(width: 8)] else
                Icon(Icons.auto_awesome, size: 20, color: c.ai),
              Expanded(
                child: Text(
                  who == null ? l.aiDelRequestedNoName(label) : l.aiDelRequested(who, label),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.35),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(aiEntityLabel(l, r.entity), style: theme.textTheme.bodySmall?.copyWith(color: c.fg2)),
          if (r.reason != null) Text(l.deletionReason(r.reason!), style: const TextStyle(fontSize: 14)),
          Text(l.deletionRequestedAt(aiDateTime(r.createdAt)), style: theme.textTheme.bodySmall?.copyWith(color: c.fg2)),
          Text(statusText, key: Key('deletion-status-${r.id}'), style: theme.textTheme.bodySmall?.copyWith(color: c.fg2)),
          if (pending) ...[
            const SizedBox(height: 8),
            Text(l.aiDelNoSilent, key: Key('deletion-note-${r.id}'), style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: Key('deletion-approve-${r.id}'),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: theme.colorScheme.surface,
                      foregroundColor: c.fail,
                      side: BorderSide(color: c.fail),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: _busyId != null || expired ? null : () => _decide(r, approve: true),
                    label: Text(l.aiDelApproveBtn),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    key: Key('deletion-reject-${r.id}'),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: theme.colorScheme.surface,
                      foregroundColor: c.fg,
                    ),
                    onPressed: _busyId != null || expired ? null : () => _decide(r, approve: false),
                    child: Text(l.deletionReject),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Sep extends StatelessWidget {
  const _Sep(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Row(
        children: [
          Expanded(child: Divider(color: c.line)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c.fg2)),
          ),
          Expanded(child: Divider(color: c.line)),
        ],
      ),
    );
  }
}
