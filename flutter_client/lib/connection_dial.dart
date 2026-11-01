part of 'main.dart';

Duration connectionMotion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 180);

class ConnectionDial extends StatefulWidget {
  const ConnectionDial({
    super.key,
    required this.running,
    required this.verified,
    required this.busy,
    required this.onPressed,
    required this.hint,
    this.startedAt,
    this.foreground = true,
    this.activeLabel,
    this.showElapsed = true,
  });
  final String? activeLabel;
  final bool showElapsed;
  final DateTime? startedAt;
  final bool foreground;
  final bool running, verified, busy;
  final VoidCallback? onPressed;
  final String hint;
  @override
  State<ConnectionDial> createState() => _ConnectionDialState();
}

class _ConnectionDialState extends State<ConnectionDial> {
  bool hovered = false, pressed = false, focused = false;
  @override
  Widget build(BuildContext context) {
    final p = appColors(context);
    final enabled = widget.onPressed != null;
    final tone = p.accent;
    final active = widget.running;
    final duration = connectionMotion(context);
    if (p.halloween) {
      return SizedBox(
        width: 188,
        height: 188,
        child: FittedBox(
          child: ConnectionOrbit(
            running: widget.running,
            verified: widget.verified,
            busy: widget.busy,
            onPressed: widget.onPressed,
            hint: widget.hint,
          ),
        ),
      );
    }
    return SizedBox(
      width: 188,
      height: 188,
      child: Stack(
        alignment: Alignment.center,
        children: [
          IgnorePointer(
            child: AnimatedContainer(
              duration: duration,
              width: 188,
              height: 188,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    tone.withValues(alpha: active ? .16 : .07),
                    tone.withValues(alpha: 0),
                  ],
                  stops: const [.4, 1],
                ),
              ),
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: active ? 1 : 0),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 650),
                curve: Curves.easeOutCubic,
                builder: (context, progress, _) => CustomPaint(
                  painter: _ConnectionDialTrack(
                    tone: tone,
                    edge: p.edge,
                    progress: progress,
                    highlighted: hovered || focused,
                  ),
                ),
              ),
            ),
          ),
          if (widget.busy)
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(17),
                child: MediaQuery.disableAnimationsOf(context)
                    ? const SizedBox.shrink()
                    : CircularProgressIndicator(strokeWidth: 2, color: tone),
              ),
            ),
          Tooltip(
            message: widget.hint,
            child: AnimatedScale(
              duration: duration,
              curve: Curves.easeOutCubic,
              scale: pressed && enabled
                  ? .96
                  : hovered && enabled
                  ? 1.025
                  : 1,
              child: AnimatedContainer(
                duration: duration,
                width: 128,
                height: 128,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: active
                        ? [Color.lerp(p.raised, tone, .28)!, p.surface]
                        : [
                            Color.lerp(p.raised, tone, hovered ? .25 : .12)!,
                            p.surface,
                          ],
                  ),
                  border: Border.all(
                    color: focused
                        ? p.ink
                        : tone.withValues(
                            alpha: enabled || widget.busy ? .8 : .25,
                          ),
                    width: focused ? 2 : 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: tone.withValues(
                        alpha: active
                            ? .16
                            : hovered
                            ? .12
                            : .035,
                      ),
                      blurRadius: 36,
                      spreadRadius: active ? 4 : 0,
                    ),
                  ],
                ),
                child: Listener(
                  onPointerDown: enabled
                      ? (_) => setState(() => pressed = true)
                      : null,
                  onPointerUp: (_) => setState(() => pressed = false),
                  onPointerCancel: (_) => setState(() => pressed = false),
                  child: TextButton(
                    key: const ValueKey('connection-power'),
                    onPressed: widget.onPressed,
                    onHover: (value) => setState(() => hovered = value),
                    onFocusChange: (value) => setState(() => focused = value),
                    style: TextButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                      backgroundColor: Colors.transparent,
                      disabledBackgroundColor: Colors.transparent,
                      overlayColor: tone.withValues(alpha: .1),
                    ),
                    child: Semantics(
                      label: widget.hint,
                      toggled: active,
                      child: ExcludeSemantics(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SvoiIcon(
                              widget.busy
                                  ? LucideIcons.ellipsis
                                  : LucideIcons.power,
                              size: active ? 30 : 42,
                              color: enabled || widget.busy ? tone : p.muted,
                            ),
                            if (active && !widget.busy) ...[
                              const SizedBox(height: 8),
                              Text(
                                widget.activeLabel ??
                                    (widget.verified
                                        ? 'Подключён'
                                        : 'VPN включён'),
                                style: TextStyle(fontSize: 11, color: p.ink),
                              ),
                              if (widget.showElapsed) const SizedBox(height: 3),
                              if (widget.showElapsed)
                                ConnectionElapsed(
                                  startedAt: widget.startedAt,
                                  foreground: widget.foreground,
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
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

class ConnectionElapsed extends StatefulWidget {
  const ConnectionElapsed({
    super.key,
    required this.startedAt,
    required this.foreground,
  });
  final DateTime? startedAt;
  final bool foreground;
  @override
  State<ConnectionElapsed> createState() => _ConnectionElapsedState();
}

class _ConnectionElapsedState extends State<ConnectionElapsed> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    syncTimer();
  }

  @override
  void didUpdateWidget(ConnectionElapsed old) {
    super.didUpdateWidget(old);
    if (old.foreground != widget.foreground ||
        old.startedAt != widget.startedAt) {
      syncTimer();
    }
  }

  void syncTimer() {
    timer?.cancel();
    timer = widget.foreground && widget.startedAt != null
        ? Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() {});
          })
        : null;
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = widget.startedAt == null
        ? null
        : DateTime.now()
              .difference(widget.startedAt!)
              .inSeconds
              .clamp(0, 999999999);
    String pad(int n) => n.toString().padLeft(2, '0');
    return Text(
      seconds == null
          ? '—:—:—'
          : '${pad(seconds ~/ 3600)}:${pad(seconds ~/ 60 % 60)}:${pad(seconds % 60)}',
      style: TextStyle(
        fontSize: 12,
        color: appColors(context).accent,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _ConnectionDialTrack extends CustomPainter {
  const _ConnectionDialTrack({
    required this.tone,
    required this.edge,
    required this.progress,
    required this.highlighted,
  });
  final Color tone, edge;
  final double progress;
  final bool highlighted;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(
      center,
      radius - 18,
      paint..color = tone.withValues(alpha: .16 + .24 * progress),
    );
    if (progress > 0) {
      final ring = Rect.fromCircle(center: center, radius: radius - 18);
      canvas.drawArc(
        ring,
        -1.5707963267948966,
        6.283185307179586 * progress,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 2.5
          ..shader = SweepGradient(
            startAngle: -1.5707963267948966,
            endAngle: 4.71238898038469,
            colors: [
              tone.withValues(alpha: .25),
              tone,
              tone.withValues(alpha: .65),
            ],
          ).createShader(ring),
      );
    }
    canvas.save();
    canvas.translate(center.dx, center.dy);
    for (var i = 0; i < 60; i++) {
      paint
        ..strokeWidth = i % 5 == 0 ? 2 : 1
        ..color = i % 5 == 0
            ? tone.withValues(
                alpha: progress > i / 60 || highlighted ? .9 : .25,
              )
            : edge;
      canvas.drawLine(
        Offset(0, -radius + 2),
        Offset(0, -radius + (i % 5 == 0 ? 11 : 7)),
        paint,
      );
      canvas.rotate(6.283185307179586 / 60);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ConnectionDialTrack old) =>
      old.tone != tone ||
      old.edge != edge ||
      old.progress != progress ||
      old.highlighted != highlighted;
}
