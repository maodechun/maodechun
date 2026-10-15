import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// 倒计时环
///
/// 围绕验证码绘制的环形进度，随 30 秒周期递减。
/// 剩余 ≤5 秒时自动变为朱砂色并加粗，提醒用户即将刷新。
class CountdownRing extends StatelessWidget {
  final double progress;   // 1.0 → 0.0
  final double size;
  final double strokeWidth;
  final bool urgent;
  final Widget? child;

  const CountdownRing({
    super.key,
    required this.progress,
    this.size = 40,
    this.strokeWidth = 2.4,
    this.urgent = false,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          progress: progress.clamp(0.0, 1.0),
          strokeWidth: strokeWidth,
          urgent: urgent,
        ),
        child: child == null
            ? null
            : Center(child: child),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final double strokeWidth;
  final bool urgent;

  _RingPainter({
    required this.progress,
    required this.strokeWidth,
    required this.urgent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;

    // 背景轨道
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = BodhiColors.divider
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 0.7,
    );

    // 进度弧
    final activeColor = urgent
        ? BodhiColors.cinnabar
        : Color.lerp(BodhiColors.goldLight, BodhiColors.gold, 1 - progress)!;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,              // 从 12 点方向开始
      math.pi * 2 * progress,    // 顺时针扫过
      false,
      Paint()
        ..color = activeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = urgent ? strokeWidth * 1.25 : strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress ||
      old.urgent != urgent ||
      old.strokeWidth != strokeWidth;
}

/// 令牌卡片内的紧凑倒计时环（环内显示剩余秒数）
class TokenCountdownRing extends StatelessWidget {
  final double progress;
  final int remainingSeconds;
  final double size;

  const TokenCountdownRing({
    super.key,
    required this.progress,
    required this.remainingSeconds,
    this.size = 36,
  });

  @override
  Widget build(BuildContext context) {
    final urgent = remainingSeconds <= 5;
    return CountdownRing(
      progress: progress,
      size: size,
      urgent: urgent,
      child: Text(
        '$remainingSeconds',
        style: TextStyle(
          fontSize: size * 0.34,
          fontFamily: 'monospace',
          fontWeight: urgent ? FontWeight.w700 : FontWeight.w500,
          color: urgent ? BodhiColors.cinnabar : BodhiColors.inkGray,
        ),
      ),
    );
  }
}
