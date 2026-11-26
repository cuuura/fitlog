// B2 소유. AI-5 삭제 요청 승인·거절(온라인 전용).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/ai_dto.dart';
import '../../core/api/api_client.dart';
import '../../core/clock.dart';
import '../../data/providers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../ai_history/ai_labels.dart';
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
        children: [for (final r in items) _tile(context, l, r, now)],
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
    return Card(
      key: Key('deletion-${r.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.label ?? r.entityId, style: theme.textTheme.titleMedium),
            Text(aiEntityLabel(l, r.entity), style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            if (r.clientName != null) Text(l.deletionRequestedBy(r.clientName!)),
            if (r.reason != null) Text(l.deletionReason(r.reason!)),
            Text(l.deletionRequestedAt(aiDateTime(r.createdAt))),
            Text(statusText, key: Key('deletion-status-${r.id}')),
            if (pending) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: Key('deletion-reject-${r.id}'),
                    onPressed: _busyId != null || expired ? null : () => _decide(r, approve: false),
                    child: Text(l.deletionReject),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: Key('deletion-approve-${r.id}'),
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                      foregroundColor: theme.colorScheme.onError,
                    ),
                    onPressed: _busyId != null || expired ? null : () => _decide(r, approve: true),
                    child: Text(l.deletionApprove),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
