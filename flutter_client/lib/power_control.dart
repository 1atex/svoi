part of 'main.dart';

class ConnectionOrbit extends StatefulWidget {
  const ConnectionOrbit({
    super.key,
    this.controlKey = const ValueKey('connection-power'),
    required this.running,
    this.verified = false,
    required this.busy,
    required this.onPressed,
    required this.hint,
  });
  final Key controlKey;
  final bool running, busy, verified;
  final VoidCallback? onPressed;
  final String hint;
  @override
  State<ConnectionOrbit> createState() => _ConnectionOrbitState();
}

class _ConnectionOrbitState extends State<ConnectionOrbit> {
  bool hovered = false, focused = false, pressed = false;
  @override
  Widget build(BuildContext context) {
    if (appColors(context).halloween) return _PumpkinPower(control: widget);
    final enabled = widget.onPressed != null;
    final color = enabled || widget.busy
        ? (widget.verified
              ? appColors(context).success
              : appColors(context).accent)
        : appColors(context).muted;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 150);
    return SizedBox(
      width: 184,
      height: 184,
      child: Stack(
        alignment: Alignment.center,
        children: [
          for (final diameter in [182.0, 150.0])
            IgnorePointer(
              child: AnimatedContainer(
                duration: duration,
                width: diameter,
                height: diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color.withValues(
                      alpha: hovered && enabled ? .26 : .12,
                    ),
                  ),
                ),
              ),
            ),
          Tooltip(
            message: widget.hint,
            child: AnimatedScale(
              scale: pressed
                  ? .96
                  : hovered && enabled
                  ? 1.035
                  : 1,
              duration: duration,
              child: AnimatedContainer(
                duration: duration,
                width: 116,
                height: 116,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: enabled
                      ? [
                          BoxShadow(
                            color: color.withValues(alpha: hovered ? .18 : .08),
                            blurRadius: 32,
                            spreadRadius: hovered ? 5 : 0,
                          ),
                        ]
                      : [],
                ),
                child: Listener(
                  onPointerDown: enabled
                      ? (_) => setState(() => pressed = true)
                      : null,
                  onPointerUp: (_) => setState(() => pressed = false),
                  onPointerCancel: (_) => setState(() => pressed = false),
                  child: TextButton(
                    key: widget.controlKey,
                    onPressed: widget.onPressed,
                    onHover: (value) => setState(() => hovered = value),
                    onFocusChange: (value) => setState(() => focused = value),
                    style: TextButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                      backgroundColor: widget.verified
                          ? appColors(context).powerOn
                          : appColors(context).powerOff,
                      disabledBackgroundColor: appColors(context).raised,
                      foregroundColor: color,
                      side: BorderSide(
                        color: focused
                            ? appColors(context).ink
                            : color.withValues(alpha: enabled ? .65 : .25),
                        width: focused ? 2 : 1,
                      ),
                      overlayColor: color.withValues(alpha: .12),
                    ),
                    child: Semantics(
                      label: widget.hint,
                      child: ExcludeSemantics(
                        child: widget.busy
                            ? SizedBox(
                                width: 32,
                                height: 32,
                                child: MediaQuery.disableAnimationsOf(context)
                                    ? SvoiIcon(
                                        LucideIcons.ellipsis,
                                        color: color,
                                      )
                                    : CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: color,
                                      ),
                              )
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SvoiIcon(
                                    LucideIcons.power,
                                    size: 32,
                                    color: color,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    widget.running
                                        ? 'Отключить VPN'
                                        : 'Подключить',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: color,
                                    ),
                                  ),
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

class _PumpkinPower extends StatefulWidget {
  const _PumpkinPower({required this.control});
  final ConnectionOrbit control;
  @override
  State<_PumpkinPower> createState() => _PumpkinPowerState();
}

class _PumpkinPowerState extends State<_PumpkinPower> {
  bool hovered = false, focused = false, pressed = false;
  @override
  Widget build(BuildContext context) {
    final control = widget.control;
    final p = appColors(context);
    final enabled = control.onPressed != null && !control.busy;
    final tone = control.verified ? p.success : p.accent;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 130);
    return SizedBox(
      width: 184,
      height: 184,
      child: Tooltip(
        message: control.hint,
        child: AnimatedScale(
          scale: pressed
              ? .96
              : hovered && enabled
              ? 1.04
              : 1,
          duration: duration,
          child: Listener(
            onPointerDown: enabled
                ? (_) => setState(() => pressed = true)
                : null,
            onPointerUp: (_) => setState(() => pressed = false),
            onPointerCancel: (_) => setState(() => pressed = false),
            child: TextButton(
              key: control.controlKey,
              onPressed: enabled ? control.onPressed : null,
              onHover: (value) => setState(() => hovered = value),
              onFocusChange: (value) => setState(() => focused = value),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                backgroundColor: Colors.transparent,
                disabledBackgroundColor: Colors.transparent,
                foregroundColor: tone,
                overlayColor: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                  side: BorderSide(
                    color: focused ? p.ink : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Semantics(
                label: control.hint,
                child: ExcludeSemantics(
                  child: Stack(
                    children: [
                      Positioned(
                        left: 7,
                        right: 7,
                        top: 0,
                        height: 163,
                        child: Opacity(
                          opacity: enabled || control.busy ? 1 : .4,
                          child: Image.asset(
                            'assets/themes/pumpkin-power.png',
                            cacheWidth: 384,
                            cacheHeight: 384,
                            fit: BoxFit.contain,
                            errorBuilder: (_, error, stack) => SvoiIcon(
                              LucideIcons.power,
                              size: 64,
                              color: tone,
                            ),
                          ),
                        ),
                      ),
                      if (control.busy)
                        Positioned.fill(
                          child: Center(
                            child: Container(
                              width: 42,
                              height: 42,
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: p.canvas.withValues(alpha: .9),
                                shape: BoxShape.circle,
                              ),
                              child: MediaQuery.disableAnimationsOf(context)
                                  ? SvoiIcon(
                                      LucideIcons.ellipsis,
                                      color: p.accent,
                                    )
                                  : CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: p.accent,
                                    ),
                            ),
                          ),
                        ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 1,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 5,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (control.running && !control.busy) ...[
                                  SvoiIcon(
                                    control.verified
                                        ? LucideIcons.shieldCheck
                                        : LucideIcons.power,
                                    color: tone,
                                    size: 12,
                                  ),
                                  const SizedBox(width: 5),
                                ],
                                Flexible(
                                  child: Text(
                                    control.busy
                                        ? 'Подождите…'
                                        : control.running
                                        ? 'Отключить VPN'
                                        : 'Подключить',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: enabled || control.busy
                                          ? tone
                                          : p.muted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NetworkBackdrop extends CustomPainter {
  const NetworkBackdrop({this.color = const Color(0xffe7b96a)});
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i < 17; i++) {
      final offset = i * 24.0;
      paint.color = color.withValues(alpha: .035 + (i % 3) * .009);
      final path = Path()
        ..moveTo(size.width * .47 + offset, -30)
        ..cubicTo(
          size.width * .37 + offset,
          115,
          size.width * .87 - offset * .15,
          40,
          size.width + 40,
          185 + offset,
        )
        ..cubicTo(
          size.width * .7,
          260 + offset,
          size.width * .8,
          420 + offset,
          size.width + 70,
          510 + offset,
        );
      canvas.drawPath(path, paint);
    }
    paint
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: .13);
    for (var y = 26.0; y < 150; y += 30) {
      for (var x = size.width * .7; x < size.width - 20; x += 30) {
        canvas.drawCircle(Offset(x, y), .7, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant NetworkBackdrop oldDelegate) =>
      color != oldDelegate.color;
}
