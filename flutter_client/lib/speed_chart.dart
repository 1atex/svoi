part of 'main.dart';

class SpeedChart extends StatelessWidget {
  const SpeedChart({super.key, required this.row, required this.maxY});
  final Map<String, dynamic> row;
  final double maxY;
  static List<Offset> points(Object? raw) => (raw is List ? raw : const [])
      .whereType<Map>()
      .where((p) => p['seconds'] is num && p['mbps'] is num)
      .map(
        (p) => Offset(
          (p['seconds'] as num).toDouble(),
          (p['mbps'] as num).toDouble(),
        ),
      )
      .where((p) => p.dx.isFinite && p.dy.isFinite && p.dx >= 0 && p.dy >= 0)
      .take(48)
      .toList();
  static double scaleFor(List<Map<String, dynamic>> rows) {
    var peak = 10.0;
    for (final r in rows) {
      for (final p in [
        ...points(r['downloadSamples']),
        ...points(r['uploadSamples']),
      ]) {
        if (p.dy > peak) peak = p.dy;
      }
    }
    return (peak * 1.1 / 10).ceil() * 10.0;
  }

  @override
  Widget build(BuildContext context) {
    final p = appColors(context);
    final down = points(row['downloadSamples']),
        up = points(row['uploadSamples']);
    final empty = down.isEmpty && up.isEmpty;
    var maxX = 4.0;
    for (final point in [...down, ...up]) {
      if (point.dx > maxX) maxX = point.dx;
    }
    return Semantics(
      label: 'График скорости. Загрузка — сплошная линия, отдача — пунктир. Мбит в секунду; время каждой фазы отсчитывается отдельно.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'СКОРОСТЬ ПО ВРЕМЕНИ',
            style: TextStyle(color: p.muted, fontSize: 10, letterSpacing: 1.1),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 140,
            child: empty
                ? Center(
                    child: Text(
                      row['state'] == 'queued' || row['state'] == 'running'
                          ? 'График появится во время замера'
                          : 'Недостаточно данных для графика',
                      style: TextStyle(color: p.muted, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  )
                : CustomPaint(
                    painter: _SpeedPainter(
                      down,
                      up,
                      maxY,
                      maxX,
                      p,
                      Theme.of(context).textTheme.bodySmall ??
                          const TextStyle(fontFamily: 'Segoe UI'),
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 20,
            runSpacing: 8,
            children: [
              _legend(p.accent, 'Загрузка', false),
              _legend(p.ink, 'Отдача', true),
              Text(
                'Мбит/с · секунды каждой фазы',
                style: TextStyle(color: p.muted, fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legend(Color color, String text, bool dashed) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 18,
        height: 6,
        child: Center(
          child: dashed
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var i = 0; i < 3; i++)
                      Container(width: 4, height: 2, color: color),
                  ],
                )
              : Container(height: 2, color: color),
        ),
      ),
      const SizedBox(width: 6),
      Text(text, style: TextStyle(color: color, fontSize: 11)),
    ],
  );
}

class _SpeedPainter extends CustomPainter {
  _SpeedPainter(
    this.down,
    this.up,
    this.maxY,
    this.maxX,
    this.p,
    this.textStyle,
  );
  final List<Offset> down, up;
  final double maxY, maxX;
  final SvoiColors p;
  final TextStyle textStyle;
  @override
  void paint(Canvas canvas, Size size) {
    const left = 38.0, bottom = 20.0;
    final width = (size.width - left - 5).clamp(1.0, double.infinity),
        height = (size.height - bottom).clamp(1.0, double.infinity);
    void label(String text, Offset position) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: textStyle.copyWith(color: p.muted, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, position);
    }

    final grid = Paint()
      ..color = p.muted.withValues(alpha: 0.16)
      ..strokeWidth = 1;
    for (var i = 0; i < 3; i++) {
      final y = height * i / 2;
      canvas.drawLine(Offset(left, y), Offset(left + width, y), grid);
      label((maxY * (1 - i / 2)).toStringAsFixed(0), Offset(0, y - 2));
    }
    label('0 с', Offset(left, height + 7));
    label(
      '${maxX.toStringAsFixed(1)} с',
      Offset((left + width - 32).clamp(left, double.infinity), height + 7),
    );
    Offset map(Offset v) => Offset(
      left + v.dx / maxX * width,
      height - (v.dy / maxY).clamp(0.0, 1.0) * height,
    );
    void series(List<Offset> points, Color color, bool dashed) {
      if (points.isEmpty) return;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      final path = Path()..moveTo(map(points.first).dx, map(points.first).dy);
      for (final point in points.skip(1)) {
        final q = map(point);
        path.lineTo(q.dx, q.dy);
      }
      if (dashed) {
        for (final metric in path.computeMetrics()) {
          for (var start = 0.0; start < metric.length; start += 10) {
            canvas.drawPath(
              metric.extractPath(start, (start + 5).clamp(0.0, metric.length)),
              paint,
            );
          }
        }
      } else {
        canvas.drawPath(path, paint);
      }
      canvas.drawCircle(map(points.last), 3, Paint()..color = color);
    }

    series(down, p.accent, false);
    series(up, p.ink.withValues(alpha: 0.8), true);
  }

  @override
  bool shouldRepaint(covariant _SpeedPainter old) =>
      old.down != down ||
      old.up != up ||
      old.maxY != maxY ||
      old.maxX != maxX ||
      old.p != p;
}
