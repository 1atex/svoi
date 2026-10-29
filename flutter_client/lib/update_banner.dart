part of 'main.dart';

/// A quiet, dismissible companion to the native Windows logon notification.
class AvailableUpdateBanner extends StatefulWidget {
  const AvailableUpdateBanner({super.key, required this.c, required this.open});
  final SvoiController c;
  final VoidCallback open;
  @override
  State<AvailableUpdateBanner> createState() => _AvailableUpdateBannerState();
}

class _AvailableUpdateBannerState extends State<AvailableUpdateBanner> {
  Timer? timer;
  Map<String, dynamic> update = {};
  bool busy = false, loading = false;
  @override
  void initState() {
    super.initState();
    widget.c.foreground.addListener(_visibility);
    unawaited(_refresh());
  }

  void _visibility() {
    if (widget.c.visible) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (!mounted || loading) return;
    loading = true;
    try {
      if (widget.c.visible) {
        final value = await widget.c.api.request('updates');
        if (mounted) setState(() => update = value);
      }
    } catch (_) {
      // Background checks must never interrupt connecting or show modal errors.
    } finally {
      loading = false;
      timer?.cancel();
      if (mounted) timer = Timer(const Duration(seconds: 30), _refresh);
    }
  }

  Future<void> _defer(String action) async {
    setState(() => busy = true);
    try {
      await widget.c.api.request(
        'updates/$action',
        method: 'POST',
        body: {
          'version': update['version'],
          if (action == 'snooze') 'hours': 24,
        },
      );
      await _refresh();
    } catch (error) {
      if (mounted) {
        widget.c.message.value = 'Не удалось сохранить выбор: $error';
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.c.foreground.removeListener(_visibility);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notice = update['notification'] as Map? ?? {};
    final until = DateTime.tryParse(notice['snoozedUntil']?.toString() ?? '');
    if (!['available', 'ready'].contains(update['state']) ||
        notice['dismissed'] == true ||
        until != null && until.isAfter(DateTime.now())) {
      return const SizedBox.shrink();
    }
    return Material(
      color: appColors(context).surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        child: Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Доступно обновление SVOI ${update['version']}',
              style: const TextStyle(fontSize: 12),
            ),
            TextButton(
              onPressed: busy ? null : widget.open,
              child: const Text('Посмотреть обновление'),
            ),
            TextButton(
              onPressed: busy ? null : () => _defer('snooze'),
              child: const Text('Напомнить завтра'),
            ),
            TextButton(
              onPressed: busy ? null : () => _defer('dismiss'),
              child: const Text('Пропустить версию'),
            ),
          ],
        ),
      ),
    );
  }
}
