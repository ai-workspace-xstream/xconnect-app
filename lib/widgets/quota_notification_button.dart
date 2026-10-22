import 'dart:async';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/notifications/quota_notifications.dart';
import '../services/sync/desktop_sync_service.dart';

class QuotaNotificationButton extends StatelessWidget {
  const QuotaNotificationButton({super.key});

  @override
  Widget build(BuildContext context) {
    final store = QuotaNotifications.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => IconButton(
        tooltip: context.l10n.get(
          store.hasUnread ? 'notificationsUnread' : 'notifications',
        ),
        icon: Badge(
          isLabelVisible: store.hasUnread,
          child: const Icon(Icons.notifications_outlined),
        ),
        onPressed: () {
          unawaited(store.markRead());
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(
                  context.l10n.get(store.notice ?? 'notificationsEmpty'),
                ),
              ),
            );
        },
      ),
    );
  }
}

class QuotaNotificationPanel extends StatelessWidget {
  const QuotaNotificationPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final store = QuotaNotifications.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.get('notifications'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          Text(context.l10n.get(store.notice ?? 'notificationsEmpty')),
          const SizedBox(height: 16),
          if (store.notice != null)
            ValueListenableBuilder<bool>(
              valueListenable: DesktopSyncService.instance.syncing,
              builder: (context, syncing, _) => OutlinedButton.icon(
                icon: const Icon(Icons.sync),
                label: Text(context.l10n.get('notificationsRefresh')),
                onPressed: syncing
                    ? null
                    : () async {
                        final result = await DesktopSyncService.instance
                            .syncNow(manual: true);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(context.l10n.get(result.message))));
                      },
              ),
            ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.get('quotaReminders')),
            subtitle: Text(context.l10n.get('quotaRemindersHelp')),
            value: store.remindersEnabled,
            onChanged: (value) => unawaited(store.setReminders(value)),
          ),
          const SizedBox(height: 8),
          Text(context.l10n.get('customConfigsRetained')),
        ],
      ),
    );
  }
}

/// Uses the same transient notification surface as sync and connection
/// feedback. The actionable condition remains available from the bell and
/// Settings; reminder preferences never hide a server suspension.
class QuotaStatusBanner extends StatefulWidget {
  const QuotaStatusBanner({super.key});

  @override
  State<QuotaStatusBanner> createState() => _QuotaStatusBannerState();
}

class _QuotaStatusBannerState extends State<QuotaStatusBanner> {
  String? _shownNotice;

  @override
  Widget build(BuildContext context) {
    final store = QuotaNotifications.instance;
    return ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          if (store.notice == null) return const SizedBox.shrink();
          if (_shownNotice == store.notice) return const SizedBox.shrink();
          _shownNotice = store.notice;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(content: Text(context.l10n.get(store.notice!))),
              );
          });
          return const SizedBox.shrink();
        });
  }
}
