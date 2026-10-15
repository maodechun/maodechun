import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// S0 启动页 · 佛祖
///
/// 动效规格（来自设计稿画板 A）：
///   总时长 1800ms
///   - 月轮光晕：0 → 600ms，scale 0.86 → 1.0，opacity 0 → 1
///   - 四字「阿弥陀佛」：起始 300ms，字间隔 120ms，单字时长 400ms
///       字 N 起始 = 300 + N * 120  →  300 / 420 / 540 / 660ms
///       单字动效：opacity 0 → 1，translateY 8px → 0
///   - 副句：1200 → 1600ms，opacity 0 → 1
///   - 停留：1600 → 1800ms
///
/// 早课 / 晚课（来自画板 B）：
///   05:00 – 17:59  早课 → 「护持正道 · 精进修行」
///   18:00 – 04:59  晚课 → 「静夜安宁 · 澄心息虑」
///
/// 开屏语音（来自画板 C）：启动时播放「南无阿弥陀佛」
class SplashPage extends StatefulWidget {
  /// 点击进入下一步的回调
  final VoidCallback onFinished;

  /// 是否启用开屏语音（由设置控制）
  final bool voiceEnabled;

  const SplashPage({
    super.key,
    required this.onFinished,
    this.voiceEnabled = true,
  });

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  static const _greetingChars = ['阿', '弥', '陀', '佛'];

  late final AnimationController _controller;
  final List<Animation<double>> _charOpacity = [];
  final List<Animation<Offset>> _charSlide = [];

  late final Animation<double> _haloOpacity;
  late final Animation<double> _haloScale;
  late final Animation<double> _subOpacity;
  late final Animation<double> _brandOpacity;

  AudioPlayer? _player;
  Timer? _finishTimer;
  bool _finished = false;

  /// 是否早课时段
  bool _isMorningClass = true;

  @override
  void initState() {
    super.initState();
    _isMorningClass = _resolveIsMorning();
    _setupAnimations();
    _playVoice();
    _start();
  }

  /// 判断早课 / 晚课时段
  bool _resolveIsMorning() {
    final hour = DateTime.now().hour;
    return hour >= 5 && hour < 18;
  }

  void _setupAnimations() {
    // 总时长 1800ms
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    const total = 1800.0;

    // 月轮光晕 0 → 600ms
    _haloOpacity = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 600 / total, curve: Curves.easeOutCubic),
    );
    _haloScale = Tween<double>(begin: 0.86, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 600 / total, curve: Curves.easeOutCubic),
      ),
    );

    // 四字：起始 300ms，每字错开 120ms，单字 400ms
    for (var i = 0; i < _greetingChars.length; i++) {
      final start = 300 + i * 120;
      final end = start + 400;
      final interval = Interval(
        start / total,
        (end / total).clamp(0.0, 1.0),
        curve: Curves.easeOutCubic,
      );
      _charOpacity.add(CurvedAnimation(parent: _controller, curve: interval));
      _charSlide.add(
        Tween<Offset>(
          begin: const Offset(0, 8),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _controller, curve: interval)),
      );
    }

    // 副句 1200 → 1600ms
    _subOpacity = CurvedAnimation(
      parent: _controller,
      curve: const Interval(1200 / total, 1600 / total, curve: Curves.easeOut),
    );

    // 品牌块 100 → 700ms（略早于问候语，视觉层次分明）
    _brandOpacity = CurvedAnimation(
      parent: _controller,
      curve: const Interval(100 / total, 700 / total, curve: Curves.easeOut),
    );
  }

  Future<void> _playVoice() async {
    if (!widget.voiceEnabled) return;
    try {
      // 系统静音 / 勿扰模式下不播放，交由系统策略决定
      _player = AudioPlayer();
      await _player!.setReleaseMode(ReleaseMode.stop);
      await _player!.play(
        AssetSource('audio/namo_amitabha.mp3'),
        volume: 1.0,
      );
    } catch (_) {
      // 语音文件缺失或播放失败不影响启动流程
    }
  }

  void _start() {
    _controller.forward();

    // 1800ms 后自动进入，或用户点击提前进入
    _finishTimer = Timer(const Duration(milliseconds: 1800), _finish);

    // 平台硬件加速可能导致的轻微延迟，补齐到 2 秒上限
    if (!Platform.isAndroid && !Platform.isIOS) {
      _finishTimer?.cancel();
      _finishTimer = Timer(const Duration(milliseconds: 2200), _finish);
    }
  }

  void _finish() {
    if (_finished || !mounted) return;
    _finished = true;
    widget.onFinished();
  }

  @override
  void dispose() {
    _finishTimer?.cancel();
    _controller.dispose();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final greetingSub = _isMorningClass
        ? '护持正道 · 精进修行'
        : '静夜安宁 · 澄心息虑';

    return GestureDetector(
      onTap: _finish,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── 佛祖背景图 ──
          _buildBackground(),

          // ── 底部渐隐遮罩（保证文字可读）──
          const DecoratedBox(
            decoration: BoxDecoration(gradient: BodhiColors.splashScrim),
          ),

          // ── 内容 ──
          SafeArea(
            child: Column(
              children: [
                const Spacer(flex: 5),

                // 品牌块
                FadeTransition(
                  opacity: _brandOpacity,
                  child: _buildBrandBlock(),
                ),

                const SizedBox(height: 26),

                // 月轮光晕 + 四字问候
                _buildGreetingBlock(greetingSub),

                const Spacer(flex: 4),

                // 版权行
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Text(
                    '道拓日记版权所有',
                    style: BodhiTypography.splashCopyright,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackground() {
    return Image.asset(
      'assets/images/splash_buddha.png',
      fit: BoxFit.cover,
      // 图片缺失时降级为墨绿渐变背景，不崩溃
      errorBuilder: (context, error, stack) => const DecoratedBox(
        decoration: BoxDecoration(gradient: BodhiColors.nightGradient),
      ),
    );
  }

  Widget _buildBrandBlock() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 金莲小徽
        SizedBox(
          width: 56,
          height: 56,
          child: CustomPaint(painter: _MiniLotusPainter()),
        ),
        const SizedBox(height: 14),
        Text('菩提护令', style: BodhiTypography.brandName),
        const SizedBox(height: 8),
        Text('一心护念 · 密钥常安', style: BodhiTypography.brandSlogan),
      ],
    );
  }

  Widget _buildGreetingBlock(String greetingSub) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 月轮光晕
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Opacity(
              opacity: _haloOpacity.value,
              child: Transform.scale(
                scale: _haloScale.value,
                child: child,
              ),
            );
          },
          child: Container(
            width: 168,
            height: 168,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  BodhiColors.goldGlow.withValues(alpha: 0.32),
                  BodhiColors.goldLight.withValues(alpha: 0.12),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
        ),

        // 四字逐字淡入
        Transform.translate(
          offset: const Offset(0, -132), // 叠在光晕中心
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(_greetingChars.length, (i) {
              return SlideTransition(
                position: _charSlide[i],
                child: FadeTransition(
                  opacity: _charOpacity[i],
                  child: Text(
                    _greetingChars[i],
                    style: BodhiTypography.greetingMain,
                  ),
                ),
              );
            }),
          ),
        ),

        // 副句
        Transform.translate(
          offset: const Offset(0, -104),
          child: FadeTransition(
            opacity: _subOpacity,
            child: Text(greetingSub, style: BodhiTypography.greetingSub),
          ),
        ),
      ],
    );
  }
}

/// 启动页金莲（轻量版，避免依赖外部资源）
class _MiniLotusPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2 - 2;

    final paint = Paint()
      ..color = BodhiColors.goldGlow
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;

    for (var i = 0; i < 8; i++) {
      final angle = (3.14159 * 2 / 8) * i - 3.14159 / 2;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(angle);
      final path = Path()
        ..moveTo(0, 0)
        ..cubicTo(
          maxR * 0.3, -maxR * 0.3,
          maxR * 0.24, -maxR * 0.75,
          0, -maxR * 0.86,
        )
        ..cubicTo(
          -maxR * 0.24, -maxR * 0.75,
          -maxR * 0.3, -maxR * 0.3,
          0, 0,
        );
      canvas.drawPath(path, paint);
      canvas.restore();
    }

    canvas.drawCircle(
      center,
      maxR * 0.16,
      Paint()..color = BodhiColors.goldGlow.withValues(alpha: 0.75),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
