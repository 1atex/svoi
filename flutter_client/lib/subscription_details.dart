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
        icon: const SvoiIcon(LucideIcons.arrowUpRight, size: 14),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

String subscriptionUpdated(Map<String, dynamic> source) {
  final fetched = DateTime.tryParse(
    source['report']?['fetchedAt']?.toString() ?? '',
  )?.toLocal();
  if (fetched == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return 'Обновлено ${two(fetched.day)}.${two(fetched.month)} · ${two(fetched.hour)}:${two(fetched.minute)}';
}

class SubscriptionHeader extends StatelessWidget {
  const SubscriptionHeader({
    super.key,
    required this.name,
    required this.source,
    required this.count,
    required this.collapsed,
    required this.onToggle,
    this.onRefresh,
    this.onProbe,
    this.onDetails,
    this.refreshing = false,
    this.refreshError,
    this.onCancelRefresh,
  });
  final String name;
  final Map<String, dynamic>? source;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;
  final VoidCallback? onRefresh, onProbe, onDetails;
  final bool refreshing;
  final String? refreshError;
  final VoidCallback? onCancelRefresh;

  @override
  Widget build(BuildContext context) {
    final updated = source == null ? '' : subscriptionUpdated(source!);
    final m = source == null
        ? <String, dynamic>{}
        : subscriptionMetadata(source!);
    final caption = [
      if (refreshing) 'Обновляем… Сохранённые серверы доступны',
      updated,
      if (m['updateHours'] != null)
        'Интервал провайдера: ${m['updateHours']} ч',
    ].where((s) => s.isNotEmpty).join(' · ');
    final title = InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          children: [
            SvoiIcon(
              collapsed ? LucideIcons.chevronRight : LucideIcons.chevronDown,
              size: 15,
              color: appColors(context).muted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (caption.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Tooltip(
                        message: caption,
                        child: Text(
                          caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: appColors(context).muted,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: 'Серверов в списке: $count',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '$count',
              style: TextStyle(fontSize: 12, color: appColors(context).muted),
            ),
          ),
        ),
        if (source?['remote'] == true)
          IconButton(
            tooltip: refreshing
                ? 'Остановить обновление $name'
                : 'Обновить $name',
            onPressed: refreshing ? onCancelRefresh : onRefresh,
            icon: SvoiIcon(
              refreshing ? LucideIcons.square : LucideIcons.refreshCw,
              size: 16,
            ),
          ),
        if (source != null)
          IconButton(
            tooltip: 'Проверить задержку подписки',
            onPressed: onProbe,
            icon: const SvoiIcon(LucideIcons.activity, size: 16),
          ),
        if (source != null)
          IconButton(
            tooltip: 'Настройки подписки',
            onPressed: onDetails,
            icon: const SvoiIcon(LucideIcons.ellipsis, size: 18),
          ),
      ],
    );
    return Theme(
      data: Theme.of(context).copyWith(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            minimumSize: const Size(32, 32),
            padding: const EdgeInsets.all(6),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            foregroundColor: appColors(context).muted,
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Material(
          color: source == null
              ? Colors.transparent
              : appColors(context).surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: source == null
                ? BorderSide.none
                : BorderSide(color: appColors(context).edge),
          ),
          child: Padding(
            padding: EdgeInsets.all(source == null ? 0 : 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (context, bounds) =>
                      bounds.maxWidth < 400 ||
                          MediaQuery.textScalerOf(context).scale(14) > 19
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            title,
                            Align(
                              alignment: Alignment.centerRight,
                              child: actions,
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(child: title),
                            actions,
                          ],
                        ),
                ),
                if (source != null)
                  SubscriptionSummary(source: source!, onDetails: onDetails),
                if (refreshing)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (refreshError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            refreshError!.split('. ').first,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color:
                                  refreshError!.startsWith(
                                    'Обновление остановлено',
                                  )
                                  ? appColors(context).muted
                                  : appColors(context).error,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Что делать с обновлением подписки',
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (dialog) => AlertDialog(
                              title: const Text('Обновление подписки'),
                              content: Text(refreshError!),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(dialog),
                                  child: const Text('Понятно'),
                                ),
                              ],
                            ),
                          ),
                          icon: const SvoiIcon(LucideIcons.info, size: 16),
                        ),
                        TextButton(
                          onPressed: onRefresh,
                          child: const Text('Повторить'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SubscriptionTrafficBar extends StatelessWidget {
  const SubscriptionTrafficBar({super.key, required this.metadata});
  final Map<String, dynamic> metadata;
  @override
  Widget build(BuildContext context) {
    final m = metadata;
    final total = m['total'] as num?;
    final hasUsage = m['upload'] != null || m['download'] != null;
    final used = (m['upload'] as num? ?? 0) + (m['download'] as num? ?? 0);
    final text =
        '${hasUsage ? subscriptionBytes(used) : 'Расход не указан'} / ${total == null
            ? '?'
            : total == 0
            ? '∞'
            : subscriptionBytes(total)}';
    final exhausted = total != null && total > 0 && hasUsage && used >= total;
    final full =
        '${subscriptionTraffic(m)}${exhausted ? ' · Лимит исчерпан' : ''}';
    return Tooltip(
      message: full,
      child: Semantics(
        label: 'Трафик подписки',
        value: full,
        child: ExcludeSemantics(
          child: SizedBox(
            height: MediaQuery.textScalerOf(context).scale(12) + 14,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: LinearProgressIndicator(
                    value: hasUsage && total != null && total > 0
                        ? (used / total).clamp(0.0, 1.0)
                        : 0,
                    borderRadius: BorderRadius.circular(7),
                    backgroundColor: appColors(context).canvas,
                    color:
                        (exhausted
                                ? Theme.of(context).colorScheme.error
                                : appColors(context).accent)
                            .withValues(alpha: .25),
                  ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(
                        color: exhausted
                            ? Theme.of(context).colorScheme.error
                            : appColors(context).edge,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SubscriptionSummary extends StatelessWidget {
  const SubscriptionSummary({super.key, required this.source, this.onDetails});
  final Map<String, dynamic> source;
  final VoidCallback? onDetails;
  @override
  Widget build(BuildContext context) {
    final m = subscriptionMetadata(source);
    final expiry = subscriptionExpiry(m);
    final hasTraffic = subscriptionTraffic(m).isNotEmpty;
    final announcement = m['announcement']?.toString() ?? '';
    if (!hasTraffic &&
        expiry.isEmpty &&
        announcement.isEmpty &&
        m['routingStatus'] == null) {
      return const SizedBox.shrink();
    }
    final date = Text(
      expiry,
      style: TextStyle(
        fontSize: 12,
        color: expiry.startsWith('Истекла')
            ? Theme.of(context).colorScheme.error
            : appColors(context).muted,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasTraffic || expiry.isNotEmpty || m['routingStatus'] != null)
            Row(
              children: [
                if (m['routingStatus'] != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: IconButton(
                      tooltip: 'Маршрутизация Happ не применена. Открыть сведения о подписке',
                      onPressed: onDetails,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(32, 32),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: SvoiIcon(
                        LucideIcons.info,
                        size: 16,
                        color: appColors(context).accent,
                      ),
                    ),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, bounds) {
                      final bar = SubscriptionTrafficBar(metadata: m);
                      if (!hasTraffic) return date;
                      if (expiry.isEmpty) return bar;
                      return bounds.maxWidth < 470 ||
                              MediaQuery.textScalerOf(context).scale(12) > 15
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [bar, const SizedBox(height: 6), date],
                            )
                          : Row(
                              children: [
                                Expanded(child: bar),
                                const SizedBox(width: 12),
                                date,
                              ],
                            );
                    },
                  ),
                ),
              ],
            ),
          if (announcement.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Tooltip(
                message: 'Сообщение провайдера: $announcement',
                child: InkWell(
                  onTap: onDetails,
                  borderRadius: BorderRadius.circular(7),
                  child: Ink(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: appColors(context).accent.withValues(alpha: .06),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Row(
                      children: [
                        SvoiIcon(
                          LucideIcons.messageSquare,
                          size: 14,
                          color: appColors(context).muted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            announcement,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: appColors(context).muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
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
            style: TextStyle(color: appColors(context).muted),
          ),
        if (m['announcement'] != null) ...[
          const SizedBox(height: 12),
          Text(
            'Сообщение провайдера',
            style: TextStyle(fontSize: 12, color: appColors(context).muted),
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
          Text(
            'Маршрутизация Happ не применена',
            style: TextStyle(
              color: appColors(context).accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            'Этот заголовок — отдельный профиль Happ. Правила внутри полных конфигураций Xray сохраняются. Конвертация профиля Happ пока не поддерживается.',
            style: TextStyle(fontSize: 12, color: appColors(context).muted),
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
              Text(
                'Сохранены для просмотра. Они не меняют ваши настройки HWID, проверки связи или интерфейса.',
                style: TextStyle(fontSize: 12, color: appColors(context).muted),
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
