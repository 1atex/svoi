part of 'main.dart';

class SubscriptionRefreshButton extends StatefulWidget {
  const SubscriptionRefreshButton({
    super.key,
    required this.name,
    required this.busy,
    required this.failed,
    this.onRefresh,
    this.onCancel,
  });
  final String name;
  final bool busy, failed;
  final VoidCallback? onRefresh, onCancel;
  @override
  State<SubscriptionRefreshButton> createState() =>
      _SubscriptionRefreshButtonState();
}

class _SubscriptionRefreshButtonState extends State<SubscriptionRefreshButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  Timer? reset;
  bool done = false, cancelled = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    sync();
  }

  void sync() {
    if (widget.busy &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context)) {
      if (!spin.isAnimating) spin.repeat();
    } else {
      spin.stop();
    }
  }

  @override
  void didUpdateWidget(SubscriptionRefreshButton old) {
    super.didUpdateWidget(old);
    if (!old.busy && widget.busy) {
      reset?.cancel();
      done = false;
      cancelled = false;
    } else if (old.busy && !widget.busy) {
      done = !widget.failed && !cancelled;
      if (done) {
        reset = Timer(const Duration(milliseconds: 1800), () {
          if (mounted) setState(() => done = false);
        });
      }
    }
    if (widget.failed) done = false;
    sync();
  }

  @override
  void dispose() {
    reset?.cancel();
    spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = appColors(context);
    return IconButton(
      tooltip: widget.busy
          ? 'Остановить обновление ${widget.name}'
          : done
          ? '${widget.name} обновлена'
          : 'Обновить ${widget.name}',
      onPressed: widget.busy
          ? widget.onCancel == null
                ? null
                : () {
                    cancelled = true;
                    widget.onCancel!();
                  }
          : widget.onRefresh,
      icon: RepaintBoundary(
        child: SizedBox(
          width: 22,
          height: 22,
          child: AnimatedSwitcher(
            duration: connectionMotion(context),
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: animation,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: widget.busy
                ? Stack(
                    key: const ValueKey('refresh-working'),
                    alignment: Alignment.center,
                    children: [
                      RotationTransition(
                        turns: spin,
                        child: SvoiIcon(
                          LucideIcons.refreshCw,
                          size: 22,
                          color: p.accent,
                        ),
                      ),
                      SvoiIcon(LucideIcons.square, size: 7, color: p.accent),
                    ],
                  )
                : SvoiIcon(
                    done ? LucideIcons.check : LucideIcons.refreshCw,
                    key: ValueKey(done ? 'refresh-done' : 'refresh-idle'),
                    size: done ? 20 : 16,
                    color: done ? p.accent : p.muted,
                  ),
          ),
        ),
      ),
    );
  }
}

class ConnectionArrival extends StatefulWidget {
  const ConnectionArrival({
    super.key,
    required this.running,
    required this.busy,
    required this.session,
    required this.foreground,
    required this.child,
  });
  final bool running, busy, foreground;
  final DateTime? session;
  final Widget child;
  @override
  State<ConnectionArrival> createState() => _ConnectionArrivalState();
}

class _ConnectionArrivalState extends State<ConnectionArrival>
    with SingleTickerProviderStateMixin {
  DateTime? completedSession;
  @override
  void initState() {
    super.initState();
    completedSession = widget.session;
  }

  late final AnimationController arrival = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 750),
    value: 1,
  );
  @override
  void didUpdateWidget(ConnectionArrival old) {
    super.didUpdateWidget(old);
    if (!widget.foreground || MediaQuery.disableAnimationsOf(context)) {
      arrival.value = 1;
    } else if (widget.running &&
        !widget.busy &&
        (!old.running || completedSession != widget.session)) {
      arrival.forward(from: 0);
    }
    if (!widget.busy) completedSession = widget.session;
  }

  @override
  void dispose() {
    arrival.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      widget.child,
      IgnorePointer(
        child: AnimatedBuilder(
          animation: arrival,
          builder: (context, _) {
            final t = arrival.value;
            if (t >= 1 || MediaQuery.disableAnimationsOf(context)) {
              return const SizedBox.shrink();
            }
            return Container(
              key: const ValueKey('connection-arrival'),
              width: 128 + 58 * Curves.easeOutCubic.transform(t),
              height: 128 + 58 * Curves.easeOutCubic.transform(t),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: appColors(context).accent
                      .withValues(alpha: (1 - t) * .75),
                  width: 2 - t,
                ),
              ),
            );
          },
        ),
      ),
    ],
  );
}
