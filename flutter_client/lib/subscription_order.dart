part of 'main.dart';

class SubscriptionDragHandle extends StatelessWidget {
  const SubscriptionDragHandle({
    super.key,
    required this.c,
    required this.source,
  });
  final SvoiController c;
  final Map<String, dynamic> source;

  @override
  Widget build(BuildContext context) {
    final id = source['id'].toString();
    final sources = c.subscriptions.value;
    final index = sources.indexWhere((s) => s['id'] == id);
    final name = subscriptionDisplayName(source);
    return Draggable<String>(
      key: ValueKey('reorder-source-$id'),
      data: id,
      maxSimultaneousDrags: sources.length > 1 ? 1 : 0,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        elevation: 8,
        color: appColors(context).raised,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 240,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: appColors(context).ink, fontSize: 14),
            ),
          ),
        ),
      ),
      child: MouseRegion(
        cursor: sources.length > 1
            ? SystemMouseCursors.grab
            : SystemMouseCursors.basic,
        child: PopupMenuButton<bool>(
          tooltip: 'Перетащить подписку или изменить порядок',
          enabled: sources.length > 1,
          icon: const SvoiIcon(LucideIcons.gripVertical, size: 16),
          onSelected: (down) {
            final target = index + (down ? 1 : -1);
            if (target >= 0 && target < sources.length) {
              c.moveSubscription(
                id,
                sources[target]['id'].toString(),
                after: down,
              );
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: false,
              enabled: index > 0,
              child: const Text('Выше'),
            ),
            PopupMenuItem(
              value: true,
              enabled: index < sources.length - 1,
              child: const Text('Ниже'),
            ),
          ],
        ),
      ),
    );
  }
}

class SubscriptionDropRegion extends StatefulWidget {
  const SubscriptionDropRegion({
    super.key,
    required this.c,
    required this.sourceId,
    required this.child,
  });
  final SvoiController c;
  final String? sourceId;
  final Widget child;

  @override
  State<SubscriptionDropRegion> createState() => _SubscriptionDropRegionState();
}

class _SubscriptionDropRegionState extends State<SubscriptionDropRegion> {
  bool after = false;
  @override
  Widget build(BuildContext context) {
    if (widget.sourceId == null) return widget.child;
    return DragTarget<String>(
      key: ValueKey('drop-source-${widget.sourceId}'),
      onWillAcceptWithDetails: (details) =>
          details.data != widget.sourceId &&
          widget.c.subscriptions.value.any((s) => s['id'] == details.data),
      onMove: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final next = box.globalToLocal(details.offset).dy > box.size.height / 2;
        if (next != after) setState(() => after = next);
      },
      onAcceptWithDetails: (details) => widget.c.moveSubscription(
        details.data,
        widget.sourceId!,
        after: after,
      ),
      builder: (context, candidates, _) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: candidates.isNotEmpty && !after
                  ? appColors(context).accent
                  : Colors.transparent,
              width: 2,
            ),
            bottom: BorderSide(
              color: candidates.isNotEmpty && after
                  ? appColors(context).accent
                  : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: widget.child,
      ),
    );
  }
}
