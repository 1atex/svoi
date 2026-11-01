part of 'main.dart';

class ConnectionSearch extends StatelessWidget {
  const ConnectionSearch({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => ShadTheme(
    data: _buttonTheme(context),
    child: Semantics(
      label: 'Поиск серверов',
      child: ShadInput(
        key: const ValueKey('desktop-server-search'),
        controller: controller,
        onChanged: onChanged,
        placeholder: const Text('Найти сервер, страну или протокол'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        leading: const SizedBox(
          width: 24,
          height: 20,
          child: Center(child: SvoiIcon(LucideIcons.search, size: 17)),
        ),
        trailing: controller.text.isEmpty
            ? null
            : SizedBox(
                width: 28,
                height: 24,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  tooltip: 'Очистить поиск',
                  onPressed: onClear,
                  icon: const SvoiIcon(LucideIcons.x, size: 16),
                ),
              ),
      ),
    ),
  );
}

class ConnectionPreviewPane extends StatelessWidget {
  const ConnectionPreviewPane({
    super.key,
    required this.c,
    required this.view,
    required this.selection,
    required this.toggle,
    required this.action,
    required this.pending,
    required this.controls,
    required this.activeName,
    required this.server,
  });
  final SvoiController c;
  final ConnectionView view;
  final Widget selection, controls;
  final VoidCallback? toggle;
  final String action, activeName;
  final bool pending;
  final ServerEntry? server;

  @override
  Widget build(BuildContext context) {
    final p = appColors(context);
    return ShadTheme(
      data: _buttonTheme(context),
      child: SingleChildScrollView(
        key: const PageStorageKey('connection-preview-pane'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RepaintBoundary(
              child: Center(
                child: ConnectionArrival(
                  running: view.running,
                  busy: view.switching,
                  session: DateTime.tryParse(
                    c.connection.value['startedAt']?.toString() ?? '',
                  ),
                  foreground: c.visible,
                  child: ConnectionDial(
                    running: view.running,
                    verified: view.verified,
                    busy: view.switching,
                    onPressed: toggle,
                    hint: action,
                    startedAt: DateTime.tryParse(
                      c.connection.value['startedAt']?.toString() ?? '',
                    ),
                    foreground: c.visible,
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: connectionMotion(context),
              alignment: Alignment.topCenter,
              child: view.needsStatus
                  ? Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 8),
                      child: Column(
                        children: [
                          Text(
                            view.title,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            view.detail,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: p.muted,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 8),
            ShadCard(
              padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
              radius: BorderRadius.circular(16),
              backgroundColor: p.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 300),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, .18),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(
                        '${server?.id}-${server?.protocol}-$pending',
                      ),
                      child: selection,
                    ),
                  ),
                  if (pending) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Сейчас: $activeName',
                      style: TextStyle(fontSize: 12, color: p.muted),
                    ),
                    const SizedBox(height: 10),
                    controls,
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            PublicIPLine(c: c),
            const SizedBox(height: 8),
            const Divider(height: 1),
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const PageStorageKey('connection-parameters'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(top: 8, bottom: 16),
                iconColor: p.accent,
                collapsedIconColor: p.muted,
                title: const Text(
                  'Параметры подключения',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${coreLabel(c.connection.value['core'] as String?)} · ${modeLabel(c.mode.value, Map<String, dynamic>.from(c.preferences.value['routing'] ?? {}))}',
                    style: TextStyle(fontSize: 12, color: p.muted),
                  ),
                ),
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: ScenarioLauncher(c: c),
                  ),
                  const SizedBox(height: 12),
                  ModePicker(c: c, concise: true),
                ],
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: 12),
            if (view.running)
              ShadButton.ghost(
                expands: true,
                enabled: !c.busy.value && !c.checking.value,
                onPressed: c.busy.value || c.checking.value ? null : c.check,
                leading: const SvoiIcon(LucideIcons.refreshCw, size: 16),
                child: Text(
                  c.checking.value
                      ? 'Проверяем интернет…'
                      : 'Проверить интернет',
                  style: const TextStyle(fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ShadButton.ghost(
              expands: true,
              onPressed: () => showDiagnostics(context, c),
              leading: const SvoiIcon(LucideIcons.activity, size: 16),
              child: const Text(
                'Подробнее о соединении',
                style: TextStyle(fontSize: 13),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
