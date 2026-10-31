part of 'main.dart';

class SubscriptionImportDialog extends StatefulWidget {
  const SubscriptionImportDialog({super.key});
  @override
  State<SubscriptionImportDialog> createState() =>
      _SubscriptionImportDialogState();
}

class _SubscriptionImportDialogState extends State<SubscriptionImportDialog> {
  final input = TextEditingController();
  String error = '', filename = '';
  int mode = 0;
  bool reading = false;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void accept(String value, {String file = ''}) {
    if (value.trim().isEmpty || value.length > 12 * 1024 * 1024) {
      setState(
        () => error = value.trim().isEmpty
            ? 'Здесь пока пусто. Скопируйте ссылку или конфигурацию.'
            : 'Размер больше 12 МБ. Выберите меньшую конфигурацию.',
      );
      return;
    }
    setState(() {
      input.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
      filename = file;
      error = '';
      if (file.isEmpty) mode = value.trim().startsWith('SVOI1.') ? 1 : 0;
    });
  }

  Future<void> paste() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (mounted) accept(data?.text ?? '');
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Не удалось прочитать буфер обмена. Вставьте текст вручную.',
        );
      }
    }
  }

  Future<void> openFile() async {
    setState(() {
      reading = true;
      error = '';
    });
    try {
      final path = await windowChannel.invokeMethod<String>('openFile');
      if (path == null || !mounted) return;
      final file = File(path);
      if (await file.length() > 12 * 1024 * 1024) {
        if (mounted) {
          setState(() => error = 'Файл больше 12 МБ. Выберите меньший файл.');
        }
        return;
      }
      final value = await file.readAsString();
      if (mounted) accept(value, file: path.split(RegExp(r'[/\\]')).last);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Не удалось прочитать файл. Выберите текстовый JSON, YAML или TXT.',
        );
      }
    } finally {
      if (mounted) setState(() => reading = false);
    }
  }

  void submit() {
    final value = input.text.trim();
    if (value.isEmpty) return;
    if (value.length > 12 * 1024 * 1024) {
      setState(
        () => error = 'Размер больше 12 МБ. Выберите меньшую конфигурацию.',
      );
      return;
    }
    Navigator.pop(context, {'content': value, 'responseFormat': 'auto'});
  }

  @override
  Widget build(BuildContext context) {
    final p = appColors(context);
    final hasInput = input.text.trim().isNotEmpty;
    final isCode = input.text.trim().startsWith('SVOI1.');
    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: SvoiIcon(LucideIcons.plus, size: 22, color: p.accent),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Text('Добавить подписку')),
        ],
      ),
      content: SizedBox(
        width: 500,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in [
                  (LucideIcons.link, 'Ссылка / текст'),
                  (LucideIcons.users, 'Код SVOI'),
                  (LucideIcons.file, 'Из файла'),
                ].indexed)
                  ChoiceChip(
                    avatar: SvoiIcon(
                      item.$2.$1,
                      size: 16,
                      color: mode == item.$1 ? p.accent : p.muted,
                    ),
                    label: Text(item.$2.$2),
                    selected: mode == item.$1,
                    showCheckmark: false,
                    onSelected: reading
                        ? null
                        : (_) => setState(() {
                            mode = item.$1;
                            error = '';
                          }),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            AnimatedSize(
              duration: connectionMotion(context),
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: connectionMotion(context),
                child: mode == 2
                    ? Container(
                        key: const ValueKey('import-file-panel'),
                        width: double.infinity,
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: p.canvas,
                          border: Border.all(color: p.edge),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          children: [
                            SvoiIcon(
                              filename.isEmpty
                                  ? LucideIcons.file
                                  : LucideIcons.fileCheck,
                              size: 32,
                              color: p.accent,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              filename.isEmpty
                                  ? 'JSON, YAML или TXT'
                                  : filename,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 16),
                            AppButton(
                              label: reading
                                  ? 'Читаем файл…'
                                  : filename.isEmpty
                                  ? 'Выбрать файл'
                                  : 'Другой файл',
                              onPressed: reading ? null : openFile,
                            ),
                          ],
                        ),
                      )
                    : Column(
                        key: ValueKey('import-text-$mode'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            mode == 1
                                ? 'Вставьте код SVOI1. Перед импортом покажем состав профиля.'
                                : 'Ссылка от провайдера или готовая конфигурация.',
                            style: TextStyle(color: p.muted, fontSize: 13),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: ValueKey('import-input-$mode'),
                            controller: input,
                            onChanged: (_) => setState(() {
                              error = '';
                              filename = '';
                            }),
                            autofocus: true,
                            minLines: 3,
                            maxLines: 6,
                            enableSuggestions: false,
                            autocorrect: false,
                            decoration: InputDecoration(
                              hintText: mode == 1 ? 'SVOI1.…' : 'https://…',
                              filled: true,
                              fillColor: p.canvas,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: paste,
                              icon: const SvoiIcon(
                                LucideIcons.clipboardPaste,
                                size: 17,
                              ),
                              label: const Text('Вставить из буфера'),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SvoiIcon(LucideIcons.layers, size: 15, color: p.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isCode ? 'Сначала просмотр, затем подтверждение импорта.' : 'Формат определим автоматически. Существующие подписки останутся.',
                    style: TextStyle(color: p.muted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        AppButton(
          label: isCode ? 'Посмотреть профиль' : 'Добавить',
          primary: true,
          icon: isCode ? LucideIcons.arrowRight : LucideIcons.plus,
          onPressed: hasInput && !reading && (mode != 2 || filename.isNotEmpty)
              ? submit
              : null,
        ),
      ],
    );
  }
}
