import 'ui_icons.dart';

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

  Future<void> _act({Uri? uri, bool acknowledge = true}) async {
    final version = widget.store.pendingVersion;
    if (_busy || version == null) return;
    setState(() => _busy = true);
    var opened = uri == null;
    try {
      if (uri != null) {
        await widget.open(uri);
        opened = true;
      }
      if (acknowledge) await widget.store.acknowledge();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              !opened ? 'Не удалось открыть ссылку. Попробуйте ещё раз.' : 'Не удалось сохранить выбор. Проверьте доступ к папке данных SVOI.',
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
          child: LayoutBuilder(
            builder: (context, bounds) {
              final title = Row(
                children: [
                  SvoiIcon(
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
                ],
              );
              final links = Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _act(
                            uri: changelogUri(
                              version,
                              platform: widget.platform,
                            ),
                          ),
                    child: const Text(
                      'Что нового',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _act(
                            uri: sourceRepositoryUri,
                            acknowledge: false,
                          ),
                    child: const Text('GitHub', style: TextStyle(fontSize: 12)),
                  ),
                ],
              );
              final close = IconButton(
                tooltip: 'Скрыть до следующего обновления',
                onPressed: _busy ? null : () => _act(),
                icon: const SvoiIcon(Icons.close, size: 18),
              );
              return bounds.maxWidth >= 640
                  ? Row(
                      children: [
                        Expanded(child: title),
                        links,
                        close,
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(child: title),
                            close,
                          ],
                        ),
                        links,
                      ],
                    );
            },
          ),
        ),
      );
    },
  );
}
