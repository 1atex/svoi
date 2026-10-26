part of 'main.dart';

Map<String, dynamic> subscriptionMetadata(Map<String, dynamic> source) =>
    Map<String, dynamic>.from(source['metadata'] as Map? ?? const {});

String subscriptionDisplayName(Map<String, dynamic> source) {
  final name = source['name']?.toString() ?? 'Подписка';
  final title = subscriptionMetadata(source)['title']?.toString() ?? '';
  return title.isNotEmpty && name == source['host'] ? title : name;
}

String subscriptionBytes(num bytes) {
  const units = ['Б', 'КиБ', 'МиБ', 'ГиБ', 'ТиБ', 'ПиБ'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String subscriptionTraffic(Map<String, dynamic> m) {
  final up = m['upload'] as num?, down = m['download'] as num?;
  final total = m['total'] as num?;
  if (up == null && down == null && total == null) return '';
  final used = up == null && down == null
      ? 'Расход не указан'
      : 'Использовано ${subscriptionBytes((up ?? 0) + (down ?? 0))}';
  return '$used · ${total == null
      ? 'лимит не указан'
      : total == 0
      ? 'без лимита'
      : 'из ${subscriptionBytes(total)}'}';
}

String subscriptionExpiry(Map<String, dynamic> m, {DateTime? now}) {
  final seconds = m['expire'] as num?;
  if (seconds == null) return '';
  if (seconds == 0) return 'Без даты окончания';
  final end = DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000);
  final stamp =
      '${end.day.toString().padLeft(2, '0')}.${end.month.toString().padLeft(2, '0')}.${end.year}';
  return end.isAfter(now ?? DateTime.now()) ? 'До $stamp' : 'Истекла $stamp';
}

Uri? subscriptionLink(String value) {
  if (value.length > 2048 || RegExp(r'[\s\\]').hasMatch(value)) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

class SubscriptionLink extends StatelessWidget {
  const SubscriptionLink({super.key, required this.label, required this.url});
  final String label, url;
  @override
  Widget build(BuildContext context) {
    final uri = subscriptionLink(url);
    if (uri == null) return const SizedBox.shrink();
    return Tooltip(
      message: uri.toString(),
      child: TextButton.icon(
        onPressed: () async {
          try {
            await windowChannel.invokeMethod<void>(
              'openExternal',
              uri.toString(),
            );
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Не удалось открыть ссылку в браузере.'),
                ),
              );
            }
          }
        },
        icon: const Icon(LucideIcons.arrowUpRight, size: 14),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

class SubscriptionSummary extends StatelessWidget {
  const SubscriptionSummary({super.key, required this.source});
  final Map<String, dynamic> source;
  @override
  Widget build(BuildContext context) {
    final m = subscriptionMetadata(source);
    final parts = [
      subscriptionTraffic(m),
      subscriptionExpiry(m),
    ].where((v) => v.isNotEmpty).toList();
    final announcement = m['announcement']?.toString() ?? '';
    if (parts.isEmpty && announcement.isEmpty && m['routingStatus'] == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (parts.isNotEmpty)
            Text(
              parts.join(' · '),
              style: const TextStyle(fontSize: 11, color: muted),
            ),
          if (announcement.isNotEmpty)
            Text(
              'От провайдера: $announcement',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: muted),
            ),
          if (m['routingStatus'] != null)
            const Text(
              'Маршрутизация Happ не применена',
              style: TextStyle(fontSize: 11, color: accent),
            ),
        ],
      ),
    );
  }
}

class SubscriptionDetails extends StatelessWidget {
  const SubscriptionDetails({super.key, required this.source});
  final Map<String, dynamic> source;
  @override
  Widget build(BuildContext context) {
    final m = subscriptionMetadata(source);
    if (m.isEmpty) return const SizedBox.shrink();
    final traffic = subscriptionTraffic(m), expiry = subscriptionExpiry(m);
    final total = m['total'] as num?;
    final hasUsage = m['upload'] != null || m['download'] != null;
    final used = (m['upload'] as num? ?? 0) + (m['download'] as num? ?? 0);
    final hints = Map<String, dynamic>.from(m['hints'] as Map? ?? const {});
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        const Text(
          'Данные провайдера',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        if (m['title'] != null) Text(m['title'].toString()),
        if (traffic.isNotEmpty) Text(traffic),
        if (total != null && total > 0 && hasUsage) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: (used / total).clamp(0.0, 1.0)),
          const SizedBox(height: 8),
          Text(
            used >= total
                ? 'Лимит трафика исчерпан'
                : 'Осталось ${subscriptionBytes(total - used)}',
          ),
        ],
        if (expiry.isNotEmpty) Text(expiry),
        if (m['updateHours'] != null)
          Text(
            'Рекомендуемое обновление: каждые ${m['updateHours']} ч',
            style: const TextStyle(color: muted),
          ),
        if (m['announcement'] != null) ...[
          const SizedBox(height: 12),
          const Text(
            'Сообщение провайдера',
            style: TextStyle(fontSize: 12, color: muted),
          ),
          SelectableText(m['announcement'].toString()),
        ],
        if (m['infoText'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(m['infoText'].toString()),
          ),
        Wrap(
          spacing: 8,
          children: [
            if (m['supportUrl'] != null)
              SubscriptionLink(label: 'Поддержка', url: m['supportUrl']),
            if (m['webUrl'] != null)
              SubscriptionLink(label: 'Личный кабинет', url: m['webUrl']),
            if (m['infoUrl'] != null)
              SubscriptionLink(
                label: m['infoButtonText'] ?? 'Подробнее',
                url: m['infoUrl'],
              ),
            if (m['renewUrl'] != null)
              SubscriptionLink(label: 'Продлить', url: m['renewUrl']),
          ],
        ),
        if (m['routingStatus'] != null) ...[
          const SizedBox(height: 8),
          const Text(
            'Маршрутизация Happ не применена',
            style: TextStyle(color: accent, fontWeight: FontWeight.w600),
          ),
          const Text(
            'Этот заголовок — отдельный профиль Happ. Правила внутри полных конфигураций Xray сохраняются. Конвертация профиля Happ пока не поддерживается.',
            style: TextStyle(fontSize: 12, color: muted),
          ),
          if (m['routing'] != null)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text(
                'Посмотреть профиль Happ',
                style: TextStyle(fontSize: 12),
              ),
              children: [
                SelectableText(
                  const JsonEncoder.withIndent('  ').convert(m['routing']),
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
        ],
        if (hints.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text(
              'Параметры провайдера',
              style: TextStyle(fontSize: 12),
            ),
            children: [
              const Text(
                'Сохранены для просмотра. Они не меняют ваши настройки HWID, проверки связи или интерфейса.',
                style: TextStyle(fontSize: 12, color: muted),
              ),
              const SizedBox(height: 8),
              for (final entry in hints.entries)
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    '${entry.key}: ${entry.value}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
