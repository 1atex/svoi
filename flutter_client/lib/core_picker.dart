part of 'main.dart';

String coreLabel(String? core) => switch (core) {
  'sing-box' => 'sing-box',
  'mihomo' => 'Mihomo',
  _ => 'Xray',
};

class CorePicker extends StatelessWidget {
  const CorePicker({super.key, required this.c});
  final SvoiController c;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([c.connection, c.busy]),
    builder: (context, _) {
      final state = c.connection.value;
      final current = state['core'] as String? ?? 'xray';
      final cores =
          (state['capabilities']?['cores'] as List? ??
                  [
                    {'id': 'xray', 'available': state['available'] == true},
                    {'id': 'sing-box', 'available': false},
                    {'id': 'mihomo', 'available': false},
                  ])
              .cast<Map>();
      final locked =
          c.busy.value ||
          ['running', 'starting', 'stopping'].contains(state['state']);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: ValueKey('core-$current'),
            initialValue: current,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Ядро подключения'),
            items: [
              for (final core in cores)
                DropdownMenuItem(
                  value: core['id'] as String,
                  enabled: core['available'] == true,
                  child: Text(
                    '${coreLabel(core['id'] as String)}${core['available'] == true ? '' : ' · недоступно'}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: locked
                ? null
                : (value) async {
                    if (value == null || value == current) return;
                    await c.action(() async {
                      c.cancelProbes();
                      final result = await c.api.request(
                        'connection/core',
                        method: 'POST',
                        body: {'core': value},
                      );
                      c.connection.value = result;
                      await c.clearProbeHistory();
                      final modes =
                          result['capabilities']?['supportedModes'] as List? ??
                          ['local'];
                      if (!modes.contains(c.mode.value)) {
                        await c.setMode(
                          modes.contains('system') && Platform.isWindows
                              ? 'system'
                              : 'local',
                        );
                      }
                    });
                  },
          ),
          const SizedBox(height: 8),
          Text(
            locked
                ? 'Чтобы сменить ядро, сначала отключите VPN.'
                : current == 'xray'
                ? 'Xray: полный профиль, TUN и прокси.'
                : '${coreLabel(current)}: простые VLESS, VMess, Trojan и Shadowsocks; ручной или системный прокси. TUN, полные профили и собственные правила маршрутизации недоступны. Для них выберите Xray.',
            style: TextStyle(
              fontSize: 12,
              color: appColors(context).muted,
              height: 1.5,
            ),
          ),
        ],
      );
    },
  );
}
