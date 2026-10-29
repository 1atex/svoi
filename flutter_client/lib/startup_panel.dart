part of 'main.dart';

class StartupPanel extends StatefulWidget {
  const StartupPanel({super.key, required this.c});
  final SvoiController c;
  @override
  State<StartupPanel> createState() => _StartupPanelState();
}

class _StartupPanelState extends State<StartupPanel> {
  Map<String, dynamic>? state;
  bool busy = false;
  String error = '';
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final result = await widget.c.api.request('startup');
      if (mounted) {
        setState(() {
          state = result;
          error = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> change({required bool enabled, required bool zapret}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await widget.c.api.request(
        'startup',
        method: 'POST',
        body: {'enabled': enabled, 'zapret': zapret},
      );
      if (mounted) setState(() => state = result);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Запускать SVOI при входе в Windows'),
        subtitle: const Text(
          'SVOI запустится в трее и сообщит о новой версии, если включена проверка обновлений. VPN подключается вручную.',
        ),
        value: state?['enabled'] == true,
        onChanged: state == null || busy
            ? null
            : (value) => change(
                enabled: value,
                zapret: value && state?['zapret'] == true,
              ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Запускать zapret вместе с Windows'),
        subtitle: Text(
          state?['strategy']?.toString().isNotEmpty == true
              ? 'Стратегия: ${state!['strategy']}. Включает автозапуск SVOI.'
              : 'Сначала выберите стратегию во вкладке zapret.',
        ),
        value: state?['enabled'] == true && state?['zapret'] == true,
        onChanged: state == null || busy
            ? null
            : (value) => change(
                enabled: value || state?['enabled'] == true,
                zapret: value,
              ),
      ),
      if (busy) const LinearProgressIndicator(),
      if (state?['elevated'] == false)
        Text(
          'Для изменения автозапуска откройте SVOI от имени администратора.',
          style: TextStyle(color: appColors(context).muted, fontSize: 12),
        ),
      if (error.isNotEmpty)
        Text(error, style: TextStyle(color: appColors(context).error)),
      if (state == null && error.isNotEmpty)
        TextButton(onPressed: load, child: const Text('Повторить')),
    ],
  );
}
