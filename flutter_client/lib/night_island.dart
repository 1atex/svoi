part of 'main.dart';

class NightIslandPanel extends StatefulWidget {
  const NightIslandPanel({super.key, required this.c});
  final SvoiController c;
  @override
  State<NightIslandPanel> createState() => _NightIslandPanelState();
}

class _NightIslandPanelState extends State<NightIslandPanel> {
  Map<String, dynamic> data = {};
  String error = '';
  bool busy = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    widget.c.foreground.addListener(refresh);
    unawaited(refresh());
  }

  Future<void> refresh() async {
    timer?.cancel();
    if (!mounted || !widget.c.visible || busy) return;
    try {
      final next = await widget.c.api.request('night-island');
      if (mounted && jsonEncode(data) != jsonEncode(next)) {
        setState(() => data = next);
      }
    } catch (_) {}
    if (mounted && widget.c.visible) {
      timer = Timer(const Duration(seconds: 2), refresh);
    }
  }

  Future<void> permit(bool enabled) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.c.api.request(
        'night-island',
        method: 'PUT',
        body: {'enabled': enabled, 'candidate': data['candidate'] ?? ''},
      );
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) {
        setState(() => busy = false);
        await refresh();
      }
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.c.foreground.removeListener(refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SwitchListTile(
        key: const ValueKey('night-island-permission'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Разрешить управление из Night Island'),
        subtitle: const Text(
          'Состояние VPN, избранные серверы и подключение. Доступ можно отозвать в любой момент.',
        ),
        value: data['enabled'] == true,
        onChanged: busy ? null : permit,
      ),
      if ((data['clientPath'] ?? '').toString().isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: SelectableText(
            'Night Island: ${data['clientPath']}',
            style: TextStyle(color: appColors(context).muted, fontSize: 12),
          ),
        ),
      if (data['enabled'] != true)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'В Night Island выберите «Настройки → Интеграции → VPN → SVOI», затем включите разрешение здесь. Оно выдаётся этому EXE только на этом компьютере.',
          ),
        ),
      if (data['clientChanged'] == true)
        const Text(
          'Сборка Night Island изменилась. Выключите разрешение и включите его снова, чтобы разрешить новую сборку.',
        ),
      if (error.isNotEmpty)
        Text(error, style: TextStyle(color: appColors(context).accent)),
    ],
  );
}
