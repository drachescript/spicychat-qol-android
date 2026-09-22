import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/android_tabs_service.dart';
import '../services/android_ui_service.dart';
import '../services/android_update_service.dart';

class AndroidSettingsScreen extends StatelessWidget {
  const AndroidSettingsScreen({super.key});

  Future<bool> _confirmEnable(BuildContext context) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Enable Android Chat Tabs?'),
            content: const Text(
              'This experimental Android-only feature keeps several chats as '
              'lightweight tabs while still using a single WebView. Inactive '
              'tabs store only their URL and scroll position.\n\n'
              'When disabled, the app keeps its normal single-page navigation '
              'and no chat-tab state is used.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Enable'),
              ),
            ],
          ),
        ) ??
        false;
  }

  String _formatLastChecked(DateTime? value) {
    if (value == null) return 'Never';

    final local = value.toLocal();
    final now = DateTime.now();
    final difference = now.difference(local);

    if (difference.inSeconds < 60) return 'Just now';
    if (difference.inMinutes < 60) {
      final minutes = difference.inMinutes;
      return '$minutes minute${minutes == 1 ? '' : 's'} ago';
    }
    if (difference.inHours < 24) {
      final hours = difference.inHours;
      return '$hours hour${hours == 1 ? '' : 's'} ago';
    }

    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _updateStatusText(AndroidUpdateService updates) {
    if (updates.checking) return 'Checking for updates…';

    switch (updates.status) {
      case AndroidUpdateStatus.updateAvailable:
        final latest = updates.latest;
        return latest == null
            ? 'A newer Android app version is available.'
            : 'Update available: v${latest.versionName}';
      case AndroidUpdateStatus.upToDate:
        return 'You are up to date.';
      case AndroidUpdateStatus.error:
        return updates.errorMessage ?? 'The update check failed.';
      case AndroidUpdateStatus.checking:
        return 'Checking for updates…';
      case AndroidUpdateStatus.idle:
        return 'No manual update check has been run yet.';
    }
  }

  Future<void> _runManualUpdateCheck(
    BuildContext context,
    AndroidUpdateService updates,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    await updates.checkForUpdates(manual: true);

    if (!context.mounted) return;

    if (updates.updateAvailable) {
      final latest = updates.latest;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            latest == null
                ? 'Android update available.'
                : 'Android update available: v${latest.versionName}',
          ),
          action: SnackBarAction(
            label: 'OPEN',
            onPressed: () {
              unawaited(updates.openLatestUpdatePage());
            },
          ),
        ),
      );
      return;
    }

    if (updates.status == AndroidUpdateStatus.upToDate) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('You already have the latest Android app version.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (updates.status == AndroidUpdateStatus.error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(updates.errorMessage ?? 'Update check failed.'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabs = context.watch<AndroidTabsService>();
    final androidUi = context.watch<AndroidUiService>();
    final updates = context.watch<AndroidUpdateService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Android Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              'ANDROID-ONLY FEATURES',
              style: TextStyle(
                color: Colors.deepPurpleAccent.withValues(alpha: 0.85),
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.system_update_alt,
                        color: Colors.deepPurpleAccent,
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Android app updates',
                        style: TextStyle(fontSize: 16),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    updates.currentVersionCode > 0
                        ? 'Installed: v${updates.currentVersionName} '
                            '(${updates.currentVersionCode})'
                        : 'Installed: v${updates.currentVersionName}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Automatic checks: every 12 hours',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Last checked: ${_formatLastChecked(updates.lastCheckedAt)}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _updateStatusText(updates),
                      style: TextStyle(
                        color: updates.status ==
                                AndroidUpdateStatus.updateAvailable
                            ? Colors.amberAccent
                            : updates.status == AndroidUpdateStatus.error
                                ? Colors.redAccent
                                : Colors.white70,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: updates.checking
                            ? null
                            : () => _runManualUpdateCheck(
                                  context,
                                  updates,
                                ),
                        icon: updates.checking
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh),
                        label: Text(
                          updates.checking
                              ? 'Checking…'
                              : 'Check for updates now',
                        ),
                      ),
                      if (updates.updateAvailable)
                        OutlinedButton.icon(
                          onPressed: () {
                            unawaited(updates.openLatestUpdatePage());
                          },
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('Open update'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Manual checks bypass the 12-hour automatic-check timer. '
                    'The app checks the website update manifest and the latest '
                    'GitHub Android release, then compares the installed build.',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Native QoL controls position',
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Choose where the Android gear sits. SpicyChat top bar '
                    'places it immediately left of the language/globe control '
                    'on Home, and immediately left of the rating button in '
                    'chats. The optional chat-tabs button remains a small '
                    'floating control.',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: androidUi.controlsPosition,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Position',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (value) {
                      if (value != null) {
                        androidUi.setControlsPosition(value);
                      }
                    },
                    items: AndroidUiService.allowedPositions
                        .map(
                          (value) => DropdownMenuItem<String>(
                            value: value,
                            child: Text(
                              AndroidUiService.labelFor(value),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Default page on app launch',
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Used when Android is not restoring a saved chat tab. '
                    'Home is SpicyChat\'s current `/` route.',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: androidUi.defaultStartPage,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Start page',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (value) {
                      if (value != null) {
                        androidUi.setDefaultStartPage(value);
                      }
                    },
                    items: AndroidUiService.startPages.keys
                        .map(
                          (value) => DropdownMenuItem<String>(
                            value: value,
                            child: Text(
                              AndroidUiService.labelForStartPage(value),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: SwitchListTile(
              title: const Text('Allow pinch-to-zoom'),
              subtitle: const Text(
                'Let SpicyChat pages be manually zoomed with pinch gestures. '
                'Disabled by default.',
              ),
              value: androidUi.zoomEnabled,
              onChanged: androidUi.setZoomEnabled,
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: SwitchListTile(
              title: const Text('Multiple Android chat tabs'),
              subtitle: const Text(
                'Opt-in. Keeps one WebView active and stores inactive chats '
                'as lightweight tab state.',
              ),
              value: tabs.enabled,
              onChanged: (value) async {
                if (value && !await _confirmEnable(context)) return;
                await tabs.setEnabled(value);
              },
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: SwitchListTile(
              title: const Text('Restore tabs after restart'),
              subtitle: const Text(
                'Reopen the saved Android tab list the next time the app starts.',
              ),
              value: tabs.restoreAfterRestart,
              onChanged: tabs.enabled
                  ? (value) => tabs.setRestoreAfterRestart(value)
                  : null,
            ),
          ),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              enabled: tabs.enabled,
              title: const Text('Maximum chat tabs'),
              subtitle: Text(
                tabs.enabled
                    ? '${tabs.maxChatTabs} chat tabs + Home'
                    : 'Enable Multiple Android chat tabs first',
              ),
              trailing: DropdownButton<int>(
                value: tabs.maxChatTabs,
                onChanged: tabs.enabled
                    ? (value) {
                        if (value != null) {
                          tabs.setMaxChatTabs(value);
                        }
                      }
                    : null,
                items: const [3, 5, 8, 12]
                    .map(
                      (value) => DropdownMenuItem<int>(
                        value: value,
                        child: Text('$value'),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
          if (tabs.enabled)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('Clear saved chat tabs'),
                subtitle: Text(
                  '${tabs.chatTabCount} chat tab'
                  '${tabs.chatTabCount == 1 ? '' : 's'} currently stored',
                ),
                onTap: () async {
                  final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Clear chat tabs?'),
                          content: const Text(
                            'This only clears Android tab state. It does not '
                            'delete any SpicyChat chats.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(true),
                              child: const Text('Clear'),
                            ),
                          ],
                        ),
                      ) ??
                      false;

                  if (confirmed) {
                    await tabs.clearTabs();
                  }
                },
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Text(
              'Chat tabs are Android-only and do not change the desktop '
              'extension. Disabling the feature returns to the normal '
              'single-WebView behavior.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
