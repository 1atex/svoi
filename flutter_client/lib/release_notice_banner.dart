import 'package:flutter/material.dart';

import 'release_notice.dart';

class ReleaseNoticeBanner extends StatefulWidget {
  const ReleaseNoticeBanner({
    super.key,
    required this.store,
    required this.open,
    this.platform = 'windows',
  });
  final ReleaseNoticeStore store;
  final Future<void> Function(Uri) open;
  final String platform;

  @override
  State<ReleaseNoticeBanner> createState() => _ReleaseNoticeBannerState();
}

class _ReleaseNoticeBannerState extends State<ReleaseNoticeBanner> {
  bool _busy = false;

  Future<void> _dismiss({bool open = false}) async {
    final version = widget.store.pendingVersion;
    if (_busy || version == null) return;
    setState(() => _busy = true);
    try {
      if (open) {
        await widget.open(changelogUri(version, platform: widget.platform));
      }
      await widget.store.acknowledge();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              open
                  ? 'Не удалось открыть историю изменений. Попробуйте ещё раз.'
                  : 'Не удалось сохранить выбор. Проверьте доступ к папке данных SVOI.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final version = widget.store.pendingVersion;
      if (version == null) return const SizedBox.shrink();
      final theme = Theme.of(context);
      return Material(
        color: theme.colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 8, 6),
          child: Row(
            children: [
              Icon(
                Icons.auto_awesome_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'SVOI обновлён до $version',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              TextButton(
                onPressed: _busy ? null : () => _dismiss(open: true),
                child: const Text('Что нового', style: TextStyle(fontSize: 12)),
              ),
              IconButton(
                tooltip: 'Скрыть до следующего обновления',
                onPressed: _busy ? null : _dismiss,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
      );
    },
  );
}
