part of 'main.dart';

class ConnectionOrbit extends StatefulWidget {
  const ConnectionOrbit({
    super.key,
    required this.running,
    this.verified = false,
    required this.busy,
    required this.onPressed,
    required this.hint,
  });
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
    final enabled = widget.onPressed != null;
    final color = enabled || widget.busy
        ? (widget.verified ? success : accent)
        : muted;
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
                    key: const ValueKey('connection-power'),
                    onPressed: widget.onPressed,
                    onHover: (value) => setState(() => hovered = value),
                    onFocusChange: (value) => setState(() => focused = value),
                    style: TextButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                      backgroundColor: widget.verified
                          ? const Color(0xff23362e)
                          : const Color(0xff342b1e),
                      disabledBackgroundColor: raised,
                      foregroundColor: color,
                      side: BorderSide(
                        color: focused
                            ? ink
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
                                    ? Icon(LucideIcons.ellipsis, color: color)
                                    : CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: color,
                                      ),
                              )
                            : Icon(LucideIcons.power, size: 39, color: color),
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

class NetworkBackdrop extends CustomPainter {
  const NetworkBackdrop();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i < 17; i++) {
      final offset = i * 24.0;
      paint.color = accent.withValues(alpha: .035 + (i % 3) * .009);
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
      ..color = accent.withValues(alpha: .13);
    for (var y = 26.0; y < 150; y += 30) {
      for (var x = size.width * .7; x < size.width - 20; x += 30) {
        canvas.drawCircle(Offset(x, y), .7, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant NetworkBackdrop oldDelegate) => false;
}
