import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// 金莲徽记
///
/// 应用品牌标识：八瓣莲花，鎏金描边。
/// 全矢量绘制，任意尺寸不失真。
class LotusBadge extends StatelessWidget {
  final double size;
  final Color color;
  final bool filled;
  final double strokeWidth;

  const LotusBadge({
    super.key,
    this.size = 56,
    this.color = BodhiColors.gold,
    this.filled = false,
    this.strokeWidth = 1.6,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _LotusPainter(
          color: color,
          filled: filled,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _LotusPainter extends CustomPainter {
  final Color color;
  final bool filled;
  final double strokeWidth;

  _LotusPainter({
    required this.color,
    required this.filled,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = math.min(size.width, size.height) / 2 - strokeWidth;
    final paint = Paint()
      ..color = color
      ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 外圈金环
    canvas.drawCircle(
      center,
      maxR,
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 0.8,
    );

    // 八瓣莲花：每瓣为一个水滴形贝塞尔路径
    const petalCount = 8;
    final petalLength = maxR * 0.82;
    final petalWidth = maxR * 0.32;

    for (var i = 0; i < petalCount; i++) {
      final angle = (math.pi * 2 / petalCount) * i - math.pi / 2;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(angle);

      final path = Path()
        ..moveTo(0, 0)
        ..cubicTo(
          petalWidth, -petalLength * 0.35,
          petalWidth * 0.75, -petalLength * 0.85,
          0, -petalLength,
        )
        ..cubicTo(
          -petalWidth * 0.75, -petalLength * 0.85,
          -petalWidth, -petalLength * 0.35,
          0, 0,
        )
        ..close();

      canvas.drawPath(path, paint);
      canvas.restore();
    }

    // 中心莲蓬（实心小圆 + 莲心点）
    canvas.drawCircle(
      center,
      maxR * 0.18,
      Paint()..color = color.withValues(alpha: filled ? 0.9 : 0.55),
    );
  }

  @override
  bool shouldRepaint(covariant _LotusPainter old) =>
      old.color != color ||
      old.filled != filled ||
      old.strokeWidth != strokeWidth;
}

/// 金莲徽章（带光晕背景，用于锁屏与解锁页）
class LotusSeal extends StatelessWidget {
  final double size;
  final bool showGlow;

  const LotusSeal({
    super.key,
    this.size = 72,
    this.showGlow = true,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * 1.5,
      height: size * 1.5,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (showGlow)
            Container(
              width: size * 1.45,
              height: size * 1.45,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    BodhiColors.goldGlow.withValues(alpha: 0.28),
                    BodhiColors.goldGlow.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: BodhiColors.cardWhite,
              border: Border.all(
                color: BodhiColors.gold.withValues(alpha: 0.45),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: BodhiColors.gold.withValues(alpha: 0.15),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Center(
              child: LotusBadge(size: size * 0.62),
            ),
          ),
        ],
      ),
    );
  }
}
