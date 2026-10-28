part of 'main.dart';

const communityChannel = 'https://t.me/SVOI_client';

class CommunityButton extends StatefulWidget {
  const CommunityButton({super.key});

  @override
  State<CommunityButton> createState() => _CommunityButtonState();
}

class _CommunityButtonState extends State<CommunityButton> {
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await windowChannel.invokeMethod<void>('openCommunity');
    } on PlatformException catch (error) {
      if (mounted) await _showFailure(error.code == 'telegram_missing');
    } on MissingPluginException {
      if (mounted) await _showFailure(false);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _showFailure(bool missing) => showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Не удалось открыть Telegram'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            missing
                ? 'Установите Telegram Desktop и войдите в аккаунт, затем нажмите кнопку канала ещё раз.'
                : 'Откройте Telegram и найдите канал @SVOI_client. Если Telegram установлен, проверьте, что Windows открывает ссылки tg: через него.',
          ),
          const SizedBox(height: 16),
          const SelectableText(communityChannel),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(
              const ClipboardData(text: communityChannel),
            );
            if (dialog.mounted) Navigator.pop(dialog);
          },
          child: const Text('Скопировать ссылку'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Новости SVOI в Telegram',
    onPressed: _opening ? null : _open,
    icon: const SvoiIcon(Icons.telegram, size: 22),
  );
}
