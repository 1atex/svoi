part of 'main.dart';

String scenarioDetail(Map<String, dynamic> s) => s['kind'] == 'zapret'
    ? 'zapret · ${s['strategy']}'
    : '${s['serverName'] ?? 'Сервер'} · ${modeLabel(s['mode'], s['routing'] as Map<String, dynamic>?)} · ${(s['directDomains'] as List? ?? []).length} сайтов напрямую';

Future<void> saveScenarioDialog(BuildContext context, SvoiController c) async {
  var name = '', kind = 'vpn', error = '';
  var saving = false;
  await showDialog<void>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: const Text('Сохранить сценарий'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('scenario-name'),
                  onChanged: (v) => name = v,
                  maxLength: 40,
                  autofocus: true,
                  enabled: !saving,
                  decoration: const InputDecoration(
                    labelText: 'Название',
                    hintText: 'Работа, игры, повседневный',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: kind,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Режим'),
                  items: const [
                    DropdownMenuItem(
                      value: 'vpn',
                      child: Text(
                        'Сервер и правила VPN',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'zapret',
                      child: Text(
                        'Стратегия zapret',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  onChanged: saving ? null : (v) => setLocal(() => kind = v!),
                ),
                const SizedBox(height: 14),
                Text(
                  'Сценарий сохранится в текущем профиле. Его запуск может переключить VPN и zapret с кратким перерывом соединения.',
                  style: TextStyle(
                    color: appColors(context).muted,
                    height: 1.5,
                  ),
                ),
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error,
                      style: TextStyle(color: appColors(context).error),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(dialog),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    if (name.trim().isEmpty) {
                      setLocal(() => error = 'Введите название сценария.');
                      return;
                    }
                    setLocal(() => saving = true);
                    await c.saveScenario(name, kind);
                    if (!context.mounted) return;
                    if (c.message.value.isEmpty) {
                      Navigator.pop(dialog);
                    } else {
                      setLocal(() {
                        error = c.message.value;
                        saving = false;
                      });
                      c.message.value = '';
                    }
                  },
            child: Text(saving ? 'Сохраняем…' : 'Сохранить'),
          ),
        ],
      ),
    ),
  );
}

class ScenarioLauncher extends StatelessWidget {
  const ScenarioLauncher({super.key, required this.c});
  final SvoiController c;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      c.scenarios,
      c.group,
      c.busy,
      c.scenarioApplying,
      c.lastScenario,
      c.servers,
    ]),
    builder: (context, _) => PopupMenuButton<String>(
      tooltip:
          'Сценарии${c.currentScenarios.where((s) => s['id'] == c.lastScenario.value).firstOrNull == null ? '' : ' · последний запуск: ${c.currentScenarios.firstWhere((s) => s['id'] == c.lastScenario.value)['name']}'}',
      enabled: !c.busy.value,
      onSelected: (id) async {
        if (id == 'save') {
          await saveScenarioDialog(context, c);
        } else if (id == 'manage') {
          if (context.mounted) {
            await showDesktopSheet(context, 'Сценарии', ScenarioManager(c: c));
          }
        } else {
          await c.applyScenario(id);
        }
      },
      itemBuilder: (context) => [
        for (final scene in c.currentScenarios)
          PopupMenuItem(
            value: scene['id'].toString(),
            enabled: c.scenarioAvailableForCore(scene),
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(scene['name'].toString()),
              subtitle: Text(scenarioDetail(scene), maxLines: 2),
            ),
          ),
        if (c.currentScenarios.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'save',
          child: Text('Сохранить текущие настройки'),
        ),
        const PopupMenuItem(
          value: 'manage',
          child: Text('Управлять сценариями'),
        ),
      ],
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: appColors(context).raised,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: appColors(context).edge),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SvoiIcon(
                LucideIcons.layers,
                size: 15,
                color: appColors(context).accent,
              ),
              SizedBox(width: 7),
              Text('Сценарии', style: TextStyle(fontSize: 12)),
              SizedBox(width: 6),
              SvoiIcon(LucideIcons.chevronDown, size: 14),
            ],
          ),
        ),
      ),
    ),
  );
}

class ScenarioManager extends StatelessWidget {
  const ScenarioManager({super.key, required this.c});
  final SvoiController c;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      c.scenarios,
      c.group,
      c.busy,
      c.lastScenario,
      c.servers,
    ]),
    builder: (context, _) => FeatureBody(
      children: [
        Section(
          'Сценарии текущего профиля',
          subtitle: 'Сохраните сервер, режим и правила VPN или стратегию zapret. Запуск доступен здесь и в трее.',
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: c.busy.value
                    ? null
                    : () => saveScenarioDialog(context, c),
                icon: const SvoiIcon(LucideIcons.plus, size: 16),
                label: const Text('Сохранить текущие настройки'),
              ),
            ),
            const SizedBox(height: 12),
            if (c.currentScenarios.any((s) => s['id'] == c.lastScenario.value))
              Text(
                'Последний запуск: ${c.currentScenarios.firstWhere((s) => s['id'] == c.lastScenario.value)['name']}',
                style: TextStyle(color: appColors(context).accent),
              ),
            if (c.currentScenarios.isEmpty)
              Text(
                'Сценариев пока нет.',
                style: TextStyle(color: appColors(context).muted),
              ),
            for (final scene in c.currentScenarios)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(scene['name'].toString()),
                subtitle: Text(
                  c.scenarioAvailableForCore(scene)
                      ? scenarioDetail(scene)
                      : '${scenarioDetail(scene)}\nНедоступен для выбранного ядра',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed:
                          c.busy.value || !c.scenarioAvailableForCore(scene)
                          ? null
                          : () => c.applyScenario(scene['id']),
                      child: const Text('Запустить'),
                    ),
                    IconButton(
                      tooltip: 'Удалить сценарий',
                      onPressed: c.busy.value
                          ? null
                          : () => c.deleteScenario(scene['id']),
                      icon: const SvoiIcon(LucideIcons.x, size: 18),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    ),
  );
}
