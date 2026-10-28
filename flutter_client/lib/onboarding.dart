part of 'main.dart';

class OnboardingHost extends StatefulWidget {
  const OnboardingHost({
    super.key,
    required this.store,
    required this.controller,
    required this.child,
    this.visible,
    this.platform = 'windows',
  });
  final ReleaseNoticeStore? store;
  final SvoiController controller;
  final ValueListenable<bool>? visible;
  final String platform;
  final Widget child;

  @override
  State<OnboardingHost> createState() => _OnboardingHostState();
}

class _OnboardingHostState extends State<OnboardingHost> {
  bool _offered = false, _scheduled = false;
  Animation<double>? _routeAnimation;

  List<Listenable> get _sources => [
    if (widget.store != null) widget.store!,
    if (widget.visible != null) widget.visible!,
    widget.controller.foreground,
    widget.controller.busy,
    widget.controller.connectionPhase,
  ];

  @override
  void initState() {
    super.initState();
    for (final source in _sources) {
      source.addListener(_schedule);
    }
  }

  @override
  void didUpdateWidget(OnboardingHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store ||
        oldWidget.controller != widget.controller ||
        oldWidget.visible != widget.visible) {
      for (final source in [
        if (oldWidget.store != null) oldWidget.store!,
        if (oldWidget.visible != null) oldWidget.visible!,
        oldWidget.controller.foreground,
        oldWidget.controller.busy,
        oldWidget.controller.connectionPhase,
      ]) {
        source.removeListener(_schedule);
      }
      for (final source in _sources) {
        source.addListener(_schedule);
      }
    }
    _schedule();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeAnimation?.removeStatusListener(_routeChanged);
    _routeAnimation = ModalRoute.of(context)?.secondaryAnimation;
    _routeAnimation?.addStatusListener(_routeChanged);
    _schedule();
  }

  void _routeChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) _schedule();
  }

  bool get _eligible =>
      mounted &&
      !_offered &&
      widget.store?.loaded == true &&
      widget.store!.onboardingPending &&
      (widget.visible?.value ?? true) &&
      widget.controller.foreground.value &&
      !widget.controller.busy.value &&
      widget.controller.connectionPhase.value.isEmpty &&
      ModalRoute.of(context)?.isCurrent == true;

  void _schedule() {
    if (_scheduled || !_eligible) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_eligible) unawaited(_show());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _show() async {
    final store = widget.store!;
    final appearance = AppearanceScope.of(context);
    if (appearance == null) return;
    _offered = true;
    final completed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => OnboardingDialog(
        appearance: appearance,
        version: store.installedVersion,
        firstInstall:
            store.onboardingFirstInstall &&
            widget.controller.servers.value.isEmpty &&
            widget.controller.subscriptions.value.isEmpty,
        platform: widget.platform,
        open: (uri) =>
            windowChannel.invokeMethod<void>('openExternal', uri.toString()),
      ),
    );
    if (!mounted) return;
    try {
      await store.completeOnboarding(reviewedRelease: completed == true);
    } catch (_) {
      if (mounted) {
        widget.controller.message.value = 'Не удалось сохранить завершение знакомства. Проверьте доступ к папке данных SVOI. Приложением можно пользоваться.';
      }
    }
  }

  @override
  void dispose() {
    for (final source in _sources) {
      source.removeListener(_schedule);
    }
    _routeAnimation?.removeStatusListener(_routeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class OnboardingDialog extends StatefulWidget {
  const OnboardingDialog({
    super.key,
    required this.appearance,
    required this.version,
    required this.firstInstall,
    required this.open,
    this.platform = 'windows',
  });
  final AppearanceStore appearance;
  final String version, platform;
  final bool firstInstall;
  final Future<void> Function(Uri) open;

  @override
  State<OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<OnboardingDialog> {
  int _step = 0;
  bool _saving = false, _opening = false;
  String? _error;
  final _scroll = ScrollController();

  Future<void> _select(AppAppearance choice) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.appearance.select(choice);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Тема применена, но не сохранена. Проверьте доступ к папке данных и выберите её ещё раз.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openLink(Uri uri) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      await widget.open(uri);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Не удалось открыть браузер. Попробуйте ещё раз или откройте svoi.space вручную.',
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _close(bool completed) => Navigator.of(context).pop(completed);

  void _next(int step) {
    setState(() {
      _step = step;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: widget.appearance,
    builder: (context, choice, _) {
      final p =
          choice == AppAppearance.system &&
              MediaQuery.platformBrightnessOf(context) == Brightness.light
          ? SvoiColors.light
          : SvoiColors.forAppearance(choice);
      return Theme(
        data: svoiTheme(palette: p),
        child: Builder(
          builder: (context) => PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _close(false);
            },
            child: Focus(
              autofocus: true,
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  _close(false);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: Dialog(
                insetPadding: EdgeInsets.all(
                  MediaQuery.sizeOf(context).width < 600 ? 12 : 24,
                ),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 780,
                    maxHeight: 760,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 14, 12, 0),
                        child: Row(
                          children: [
                            SvoiIcon(
                              Icons.tune_rounded,
                              color: p.accent,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                widget.firstInstall
                                    ? 'Добро пожаловать в SVOI'
                                    : 'SVOI обновлён · ${widget.version}',
                                style: TextStyle(fontSize: 12, color: p.muted),
                              ),
                            ),
                            Text(
                              '${_step + 1} / 2',
                              style: TextStyle(fontSize: 12, color: p.muted),
                            ),
                            IconButton(
                              tooltip: 'Пропустить знакомство',
                              onPressed: () => _close(false),
                              icon: const SvoiIcon(Icons.close, size: 19),
                            ),
                          ],
                        ),
                      ),
                      Flexible(
                        child: SingleChildScrollView(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
                          child: _step == 0 ? _themes(p, choice) : _ready(p),
                        ),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: TextStyle(color: p.error, fontSize: 12),
                            ),
                          ),
                        ),
                      Divider(height: 1, color: p.edge),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: OverflowBar(
                          alignment: MainAxisAlignment.spaceBetween,
                          overflowAlignment: OverflowBarAlignment.end,
                          spacing: 12,
                          overflowSpacing: 8,
                          children: [
                            TextButton(
                              onPressed: () =>
                                  _step == 0 ? _close(false) : _next(0),
                              child: Text(_step == 0 ? 'Пропустить' : 'Назад'),
                            ),
                            FilledButton(
                              onPressed: _saving
                                  ? null
                                  : () => _step == 0 ? _next(1) : _close(true),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Text(
                                  _saving
                                      ? 'Сохраняем…'
                                      : _step == 0
                                      ? 'Продолжить'
                                      : 'Готово',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _themes(SvoiColors p, AppAppearance selected) {
    const labels = {
      AppAppearance.dark: 'Классика',
      AppAppearance.light: 'Светлая',
      AppAppearance.system: 'Как в системе',
      AppAppearance.mono: 'AMOLED',
      AppAppearance.ocean: 'Океан',
      AppAppearance.emerald: 'Изумруд',
      AppAppearance.rose: 'Роза',
      AppAppearance.halloween: 'Хэллоуин',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Свой цвет.\nСвоя атмосфера.',
          style: TextStyle(
            fontSize: 30,
            height: 1.12,
            fontWeight: FontWeight.w700,
            color: p.ink,
            letterSpacing: -.7,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Выберите оформление. Оно изменится сразу — VPN и подписки останутся как были.',
          style: TextStyle(fontSize: 13, height: 1.6, color: p.muted),
        ),
        const SizedBox(height: 22),
        _OnboardingPreview(
          palette: p,
          pumpkin: selected == AppAppearance.halloween,
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, bounds) {
            final columns = bounds.maxWidth >= 600 ? 4 : 2;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final entry in labels.entries)
                  SizedBox(
                    width: (bounds.maxWidth - (columns - 1) * 10) / columns,
                    child: IgnorePointer(
                      ignoring: _saving,
                      child: _AppearanceCard(
                        choice: entry.key,
                        label: entry.value,
                        selected: selected == entry.key,
                        onPressed: () => unawaited(_select(entry.key)),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 14),
        Text(
          'Позже: Настройки → Оформление.',
          style: TextStyle(fontSize: 12, color: p.muted),
        ),
      ],
    );
  }

  Widget _ready(SvoiColors p) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.all(17),
          decoration: BoxDecoration(
            color: p.selected,
            borderRadius: BorderRadius.circular(18),
          ),
          child: SvoiIcon(Icons.check_rounded, size: 34, color: p.accent),
        ),
      ),
      const SizedBox(height: 24),
      Text(
        widget.firstInstall ? 'Теперь — подключаться.' : 'Всё на своих местах.',
        style: TextStyle(
          fontSize: 29,
          fontWeight: FontWeight.w700,
          color: p.ink,
          letterSpacing: -.6,
        ),
      ),
      const SizedBox(height: 14),
      Text(
        widget.firstInstall
            ? 'Добавьте ссылку на подписку или импортируйте общий профиль. Затем выберите сервер и нажмите кнопку включения.'
            : 'Ваши подписки, выбранный сервер и правила сохранены. Тему можно поменять в настройках в любой момент.',
        style: TextStyle(color: p.muted, height: 1.7, fontSize: 14),
      ),
      const SizedBox(height: 26),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: p.canvas,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: p.edge),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Что нового в ${widget.version}',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: p.ink,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Новые возможности и исправления — в истории именно установленной версии.',
              style: TextStyle(color: p.muted, height: 1.6, fontSize: 13),
            ),
            const SizedBox(height: 13),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _opening
                      ? null
                      : () => _openLink(
                          changelogUri(
                            widget.version,
                            platform: widget.platform,
                          ),
                        ),
                  icon: const SvoiIcon(Icons.open_in_new, size: 16),
                  label: Text(_opening ? 'Открываем…' : 'Посмотреть изменения'),
                ),
                TextButton.icon(
                  onPressed: _opening
                      ? null
                      : () => _openLink(sourceRepositoryUri),
                  icon: const SvoiIcon(Icons.code_rounded, size: 16),
                  label: const Text('GitHub'),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}

class _OnboardingPreview extends StatelessWidget {
  const _OnboardingPreview({required this.palette, required this.pumpkin});
  final SvoiColors palette;
  final bool pumpkin;
  @override
  Widget build(BuildContext context) {
    final p = palette;
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: p.canvas,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.edge),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SVOI',
                    style: TextStyle(
                      color: p.ink,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: p.selected,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Подключение',
                      style: TextStyle(color: p.accent, fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    'Превью оформления',
                    style: TextStyle(color: p.muted, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 20),
            if (pumpkin)
              CustomPaint(
                size: const Size(68, 68),
                painter: PumpkinPainter(p.accent),
              )
            else
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: p.powerOff,
                  border: Border.all(color: p.accent),
                ),
                child: SvoiIcon(LucideIcons.power, color: p.accent, size: 29),
              ),
          ],
        ),
      ),
    );
  }
}
