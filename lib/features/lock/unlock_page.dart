import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/lotus_badge.dart';

/// S1 锁屏 · 菩提护令
///
/// 简短遮罩页：金莲徽记 + 应用名 + 轻触解锁提示。
/// 轻触 / 上滑 / 生物识别成功 → 进入 S3 解锁页。
class LockCoverPage extends StatefulWidget {
  final VoidCallback onUnlock;
  final bool biometricEnabled;

  const LockCoverPage({
    super.key,
    required this.onUnlock,
    this.biometricEnabled = true,
  });

  @override
  State<LockCoverPage> createState() => _LockCoverPageState();
}

class _LockCoverPageState extends State<LockCoverPage> {
  bool _triggered = false;

  void _handleTap() {
    if (_triggered) return;
    _triggered = true;
    widget.onUnlock();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      onVerticalDragEnd: (_) => _handleTap(),
      behavior: HitTestBehavior.opaque,
      child: DecoratedBox(
        decoration: const BoxDecoration(gradient: BodhiColors.pageGradient),
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 3),
              const LotusSeal(size: 88),
              const SizedBox(height: 24),
              Text(
                '菩提护令',
                style: BodhiTypography.brandName.copyWith(
                  color: BodhiColors.inkBrown,
                  fontSize: 24,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '一心护念 · 密钥常安',
                style: BodhiTypography.brandSlogan.copyWith(
                  color: BodhiColors.inkGray,
                ),
              ),
              const Spacer(flex: 4),
              _buildUnlockHint(),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUnlockHint() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.biometricEnabled)
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Icon(
              Icons.fingerprint,
              size: 32,
              color: BodhiColors.gold,
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.lock_outline,
              size: 14,
              color: BodhiColors.inkFaint,
            ),
            const SizedBox(width: 6),
            Text(
              '轻触解锁',
              style: BodhiTypography.caption.copyWith(
                color: BodhiColors.inkFaint,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// S3 解锁 · 密码与生物识别
///
/// 三种解锁方式：
///   1. 6 位数字密码
///   2. 指纹识别
///   3. 3D 人脸识别（与指纹走同一通路，由系统决定）
///
/// 防暴力破解：连续错误 5 次锁定 30 秒，10 次锁定 5 分钟。
class UnlockPage extends StatefulWidget {
  final VoidCallback onUnlocked;

  /// 密码由主壳层提供校验（密码本身也加密存储）
  final Future<bool> Function(String input) verifyPassword;

  final bool passwordEnabled;
  final bool fingerprintEnabled;
  final bool faceEnabled;

  const UnlockPage({
    super.key,
    required this.onUnlocked,
    required this.verifyPassword,
    this.passwordEnabled = true,
    this.fingerprintEnabled = true,
    this.faceEnabled = false,
  });

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  static const int _passwordLength = 6;

  final LocalAuthentication _localAuth = LocalAuthentication();
  final List<String> _input = [];

  bool _checking = false;
  bool _hasBiometric = false;
  String? _errorMessage;

  /// 失败计数与锁定截止时间
  int _failCount = 0;
  DateTime? _lockedUntil;
  Timer? _lockTimer;

  @override
  void initState() {
    super.initState();
    _initBiometric();
    _loadFailState();
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    super.dispose();
  }

  Future<void> _initBiometric() async {
    try {
      final supported = await _localAuth.isDeviceSupported();
      final canCheck = await _localAuth.canCheckBiometrics;
      final available = await _localAuth.getAvailableBiometrics();

      if (!mounted) return;
      setState(() {
        _hasBiometric = supported && canCheck && available.isNotEmpty;
      });

      // 有生物识别且已开启时，自动唤起一次
      if (_hasBiometric && (widget.fingerprintEnabled || widget.faceEnabled)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (mounted) await _authenticate();
      }
    } catch (_) {
      if (mounted) setState(() => _hasBiometric = false);
    }
  }

  Future<void> _loadFailState() async {
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getInt('unlock_locked_until') ?? 0;
    final count = prefs.getInt('unlock_fail_count') ?? 0;
    if (!mounted) return;
    setState(() {
      _failCount = count;
      if (until > 0 && DateTime.now().millisecondsSinceEpoch < until) {
        _lockedUntil = DateTime.fromMillisecondsSinceEpoch(until);
        _startLockCountdown();
      }
    });
  }

  Future<void> _saveFailState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('unlock_fail_count', _failCount);
    await prefs.setInt(
      'unlock_locked_until',
      _lockedUntil?.millisecondsSinceEpoch ?? 0,
    );
  }

  /// 锁定剩余秒数
  int get _lockRemaining {
    final until = _lockedUntil;
    if (until == null) return 0;
    final diff = until.difference(DateTime.now()).inSeconds;
    return diff > 0 ? diff : 0;
  }

  bool get _isLocked => _lockRemaining > 0;

  void _startLockCountdown() {
    _lockTimer?.cancel();
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_lockRemaining <= 0) {
        timer.cancel();
        setState(() {
          _lockedUntil = null;
          _errorMessage = null;
        });
        _saveFailState();
      } else {
        setState(() {});
      }
    });
  }

  // ── 密码输入 ─────────────────────────────────────────

  void _onDigit(String digit) {
    if (_checking || _isLocked) return;
    if (_input.length >= _passwordLength) return;
    HapticFeedback.lightImpact();
    setState(() {
      _input.add(digit);
      _errorMessage = null;
    });

    if (_input.length == _passwordLength) {
      _submit();
    }
  }

  void _onBackspace() {
    if (_checking || _input.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _input.removeLast());
  }

  Future<void> _submit() async {
    if (_checking) return;
    setState(() => _checking = true);

    final password = _input.join();
    final ok = await widget.verifyPassword(password);

    if (!mounted) return;

    if (ok) {
      _failCount = 0;
      _lockedUntil = null;
      await _saveFailState();
      if (!mounted) return;
      setState(() => _checking = false);
      widget.onUnlocked();
      return;
    }

    // 失败
    _failCount++;
    await _vibrateFail();

    String message;
    if (_failCount >= 10) {
      _lockedUntil = DateTime.now().add(const Duration(minutes: 5));
      _startLockCountdown();
      message = '密码错误次数过多，已锁定 5 分钟';
    } else if (_failCount >= 5) {
      _lockedUntil = DateTime.now().add(const Duration(seconds: 30));
      _startLockCountdown();
      message = '密码错误，已锁定 30 秒';
    } else {
      message = '密码错误，还可尝试 ${5 - _failCount} 次';
    }

    await _saveFailState();
    if (!mounted) return;
    setState(() {
      _input.clear();
      _checking = false;
      _errorMessage = message;
    });
  }

  Future<void> _vibrateFail() async {
    try {
      if (await Vibration.hasVibrator() ?? false) {
        await Vibration.vibrate(duration: 120);
      }
    } catch (_) {}
  }

  // ── 生物识别 ─────────────────────────────────────────

  Future<void> _authenticate() async {
    if (_checking) return;
    if (!widget.fingerprintEnabled && !widget.faceEnabled) return;

    setState(() => _checking = true);

    try {
      final ok = await _localAuth.authenticate(
        localizedReason: '解锁菩提护令以查看您的动态令牌',
        options: const AuthenticationOptions(
          // 只走指纹/人脸，不要求系统锁屏凭据：
          // 用户用的是本 App 自己的密码，若设备未设系统锁屏，
          // biometricOnly=false 时部分机型会直接抛错导致"设备不支持"
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: false,
        ),
      );

      if (!mounted) return;
      setState(() => _checking = false);

      if (ok) {
        _failCount = 0;
        await _saveFailState();
        widget.onUnlocked();
      } else {
        // 用户取消或识别失败：降级为密码输入，不弹系统锁定
        setState(() {
          _errorMessage = widget.passwordEnabled
              ? '识别未通过，请使用密码解锁'
              : '识别未通过，请重试';
        });
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _errorMessage = _biometricErrorHint(e);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _errorMessage = '生物识别启动失败，请使用密码解锁';
      });
    }
  }

  /// 把 local_auth 错误码翻译成用户能懂、能自救的提示
  String _biometricErrorHint(PlatformException e) {
    switch (e.code) {
      case 'no_hardware':
        return '未检测到指纹/人脸硬件，请使用密码解锁';
      case 'none_enrolled':
        return '尚未录入指纹/人脸，请到手机「设置 → 密码与安全」录入后，回到本页点击指纹按钮重试';
      case 'no_device_credential':
      case 'device_credential_required':
        return '请先在手机系统设置里设置一次锁屏密码，之后指纹/人脸即可使用';
      case 'locked_out':
      case 'permanently_locked_out':
        return '生物识别已被系统临时锁定，请用密码解锁后稍后再试';
      case 'no_fragment_activity':
        return '生物识别组件初始化异常，请退出应用重新打开再试';
      default:
        return '生物识别暂不可用（${e.code}），请使用密码解锁';
    }
  }

  // ── 构建 ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: BodhiColors.pageGradient),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),
            const LotusSeal(size: 72, showGlow: true),
            const SizedBox(height: 16),
            Text(
              '阿弥陀佛',
              style: BodhiTypography.greetingMain.copyWith(
                color: BodhiColors.inkBrown,
                fontSize: 20,
                letterSpacing: 6,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _isLocked
                  ? '请稍后再试'
                  : '请输入 6 位密码解锁',
              style: BodhiTypography.caption,
            ),
            const SizedBox(height: 18),

            // 密码点
            _buildDots(),

            // 错误提示
            SizedBox(
              height: 30,
              child: Center(
                child: _errorMessage == null
                    ? const SizedBox.shrink()
                    : Text(
                        _errorMessage!,
                        style: BodhiTypography.caption.copyWith(
                          color: BodhiColors.cinnabar,
                        ),
                        textAlign: TextAlign.center,
                      ),
              ),
            ),

            const Spacer(),

            // 生物识别入口
            _buildBiometricRow(),

            const SizedBox(height: 12),

            // 数字键盘
            _buildKeypad(),

            const SizedBox(height: 12),

            // 防暴力破解说明
            Text(
              '连续输错 5 次将锁定 30 秒',
              style: BodhiTypography.caption.copyWith(
                fontSize: 10,
                color: BodhiColors.inkFaint,
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_passwordLength, (i) {
        final filled = i < _input.length;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 7),
          width: filled ? 14 : 12,
          height: filled ? 14 : 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? BodhiColors.gold : Colors.transparent,
            border: Border.all(
              color: filled ? BodhiColors.gold : BodhiColors.switchOff,
              width: 1.5,
            ),
          ),
        );
      }),
    );
  }

  Widget _buildBiometricRow() {
    if (!_hasBiometric) return const SizedBox(height: 40);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.fingerprintEnabled)
          _biometricButton(
            icon: Icons.fingerprint,
            label: '指纹解锁',
            onTap: _isLocked ? null : _authenticate,
          ),
        if (widget.fingerprintEnabled && widget.faceEnabled)
          const SizedBox(width: 40),
        if (widget.faceEnabled)
          _biometricButton(
            icon: Icons.face_retouching_natural,
            label: '3D 人脸',
            onTap: _isLocked ? null : _authenticate,
          ),
      ],
    );
  }

  Widget _biometricButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 30,
            color: onTap == null
                ? BodhiColors.inkFaint
                : BodhiColors.gold,
          ),
          const SizedBox(height: 4),
          Text(label, style: BodhiTypography.keypadLabel),
        ],
      ),
    );
  }

  // ── 数字键盘 3×4 ─────────────────────────────────────
  Widget _buildKeypad() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          _keypadRow(['1', '2', '3']),
          const SizedBox(height: 6),
          _keypadRow(['4', '5', '6']),
          const SizedBox(height: 6),
          _keypadRow(['7', '8', '9']),
          const SizedBox(height: 6),
          Row(
            children: [
              // 左下：生物识别（无则占位）
              Expanded(
                child: _hasBiometric
                    ? _keypadIconButton(
                        icon: Icons.fingerprint,
                        onTap: _isLocked ? null : _authenticate,
                      )
                    : const SizedBox(height: 56),
              ),
              Expanded(child: _keypadDigit('0')),
              // 右下：退格
              Expanded(
                child: _keypadIconButton(
                  icon: Icons.backspace_outlined,
                  onTap: _onBackspace,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _keypadRow(List<String> digits) {
    return Row(
      children: digits.map((d) => Expanded(child: _keypadDigit(d))).toList(),
    );
  }

  Widget _keypadDigit(String digit) {
    final enabled = !_isLocked && !_checking;
    return SizedBox(
      height: 56,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? () => _onDigit(digit) : null,
          borderRadius: BorderRadius.circular(28),
          child: Center(
            child: Text(
              digit,
              style: BodhiTypography.keypadDigit.copyWith(
                color: enabled
                    ? BodhiColors.inkBrown
                    : BodhiColors.inkFaint,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _keypadIconButton({
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    return SizedBox(
      height: 56,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(28),
          child: Center(
            child: Icon(
              icon,
              size: 22,
              color: onTap == null
                  ? BodhiColors.inkFaint
                  : BodhiColors.inkBrown,
            ),
          ),
        ),
      ),
    );
  }
}
