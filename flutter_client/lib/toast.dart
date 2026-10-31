part of 'main.dart';

class SvoiToastHost extends StatefulWidget {
  const SvoiToastHost({super.key, required this.c});
  final SvoiController c;
  @override
  State<SvoiToastHost> createState() => _SvoiToastHostState();
}

class _SvoiToastHostState extends State<SvoiToastHost> {
  AppNotice? current;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    widget.c.notice.addListener(receive);
    widget.c.foreground.addListener(visibility);
  }

  @override
  void didUpdateWidget(SvoiToastHost old) {
    super.didUpdateWidget(old);
    if (old.c != widget.c) {
      old.c.notice.removeListener(receive);
      old.c.foreground.removeListener(visibility);
      widget.c.notice.addListener(receive);
      widget.c.foreground.addListener(visibility);
      timer?.cancel();
      current = null;
    }
  }

  void receive() {
    if (!mounted || !widget.c.visible || widget.c.notice.value == null) return;
    setState(() => current = widget.c.notice.value);
    schedule();
  }

  void schedule() {
    timer?.cancel();
    if (current != null) {
      timer = Timer(Duration(seconds: current!.warning ? 7 : 4), dismiss);
    }
  }

  void dismiss() {
    timer?.cancel();
    if (mounted) setState(() => current = null);
  }

  void visibility() {
    if (!widget.c.visible) dismiss();
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.c.notice.removeListener(receive);
    widget.c.foreground.removeListener(visibility);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = appColors(context);
    return AnimatedSwitcher(
      duration: connectionMotion(context),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, .12),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: current == null
          ? const SizedBox.shrink()
          : MouseRegion(
              key: ObjectKey(current),
              onEnter: (_) => timer?.cancel(),
              onExit: (_) => schedule(),
              child: Semantics(
                liveRegion: true,
                child: Material(
                  color: p.surface,
                  elevation: 8,
                  shadowColor: Colors.black.withValues(alpha: .2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: p.edge),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
                    child: Row(
                      children: [
                        SvoiIcon(
                          current!.warning
                              ? LucideIcons.info
                              : LucideIcons.check,
                          size: 20,
                          color: current!.warning ? p.accent : p.success,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            current!.text,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: p.ink,
                            ),
                          ),
                        ),
                        Semantics(
                          label: 'Закрыть уведомление',
                          button: true,
                          child: IconButton(
                            key: const ValueKey('toast-close'),
                            onPressed: dismiss,
                            icon: SvoiIcon(
                              LucideIcons.x,
                              size: 16,
                              color: p.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
