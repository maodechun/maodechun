import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/common.dart';
import 'account_api.dart';
import 'account_session.dart';
import 'email_bridge.dart';
import 'login_page.dart';

/// 用户注册页
///
/// 手机号 + 邮箱 + 密码 + 邮箱验证码注册，注册成功即自动登录。
/// 验证码由原生 SMTP 引擎（EmailEngine.kt）直接发送，
/// 凭据内置原生层，Dart 侧拿不到任何账号信息。
class RegisterPage extends StatefulWidget {
  final VoidCallback? onSuccess;

  const RegisterPage({super.key, this.onSuccess});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _nickController = TextEditingController();
  final _passController = TextEditingController();
  final _pass2Controller = TextEditingController();
  final _codeController = TextEditingController();
  bool _obscure = true;
  bool _obscure2 = true;
  bool _busy = false;

  // 验证码（内存保存 10 分钟，不落盘）
  String _pendingCode = '';
  DateTime _codeExpiresAt = DateTime.now();
  bool _sendingCode = false;
  int _resendCountdown = 0;

  @override
  void initState() {
    super.initState();
    _tickResend();
  }

  void _tickResend() {
    if (_resendCountdown > 0) {
      Future.delayed(const Duration(seconds: 1), () {
        if (!mounted) return;
        setState(() => _resendCountdown--);
        _tickResend();
      });
    }
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _emailController.dispose();
    _nickController.dispose();
    _passController.dispose();
    _pass2Controller.dispose();
    _codeController.dispose();
    super.dispose();
  }

  String? get _phoneError {
    final p = _phoneController.text.trim();
    if (p.isEmpty) return null;
    // 中国大陆手机号 11 位；其余号码放宽到 5~15 位数字
    final ok = RegExp(r'^1[3-9]\d{9}$').hasMatch(p) ||
        RegExp(r'^\d{5,15}$').hasMatch(p);
    if (!ok) return '手机号格式不正确';
    return null;
  }

  String? get _emailError {
    final e = _emailController.text.trim();
    if (e.isEmpty) return null;
    final ok = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(e) &&
        e.length <= 64;
    if (!ok) return '邮箱格式不正确';
    return null;
  }

  bool get _canSubmit =>
      !_busy &&
      _phoneError == null &&
      _emailError == null &&
      _phoneController.text.trim().isNotEmpty &&
      _emailController.text.trim().isNotEmpty &&
      _codeController.text.trim().length == 6 &&
      _passController.text.length >= 6 &&
      _passController.text == _pass2Controller.text;

  /// 发送邮箱验证码（原生 SMTP 直发）
  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (_emailError != null || email.isEmpty) {
      _showSnack('请先填写正确的邮箱地址');
      return;
    }
    if (_sendingCode || _resendCountdown > 0) return;
    setState(() => _sendingCode = true);
    try {
      final code = (100000 + Random().nextInt(900000)).toString();
      await EmailBridge.instance.sendVerificationCode(
        to: email,
        code: code,
      );
      _pendingCode = code;
      _codeExpiresAt = DateTime.now().add(const Duration(minutes: 10));
      if (!mounted) return;
      setState(() => _resendCountdown = 60);
      _tickResend();
      _showSnack('验证码已发送到 $email，请查收（含垃圾邮件文件夹）');
    } on EmailException catch (e) {
      if (!mounted) return;
      _showSnack('验证码发送失败：${e.message}');
    } catch (_) {
      if (!mounted) return;
      _showSnack('验证码发送失败，请检查网络后重试');
    } finally {
      if (mounted) setState(() => _sendingCode = false);
    }
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    _hideKeyboard();

    // 验证码本地校验（10 分钟有效）
    final input = _codeController.text.trim();
    if (_pendingCode.isEmpty ||
        DateTime.now().isAfter(_codeExpiresAt) ||
        input != _pendingCode) {
      _showSnack('验证码不正确或已过期，请重新获取');
      return;
    }

    setState(() => _busy = true);

    try {
      final result = await AccountApi.instance.register(
        phone: _phoneController.text.trim(),
        password: _passController.text,
        nickname: _nickController.text.trim(),
        email: _emailController.text.trim(),
      );
      await AccountSession.instance.save(
        token: result.token,
        phone: result.phone,
        nickname: result.nickname,
        createdAt: result.createdAt,
      );
      if (!mounted) return;
      _showSnack('注册成功，已自动登录');
      widget.onSuccess?.call();
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      _showSnack(e.message);
    } catch (e) {
      if (!mounted) return;
      _showSnack('网络异常，请检查网络后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _gotoLogin() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
  }

  void _hideKeyboard() =>
      FocusManager.instance.primaryFocus?.unfocus();

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: BodhiTypography.caption.copyWith(
            color: BodhiColors.paperLight,
          ),
        ),
        backgroundColor: BodhiColors.inkBrown,
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final passMismatch = _pass2Controller.text.isNotEmpty &&
        _passController.text != _pass2Controller.text;

    return DecoratedBox(
      decoration: const BoxDecoration(gradient: BodhiColors.pageGradient),
      child: SafeArea(
        child: Column(
          children: [
            BodhiNavBar(
              title: '用户注册',
              onBack: _busy ? null : () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const TipBar(
                      text: '注册需手机号、邮箱与密码。注册后可使用云备份与'
                          '云恢复（以您的用户名创建备份）。密码经服务端'
                          '加密保存，任何人（包括开发者）都无法看到明文。',
                    ),
                    const SizedBox(height: 16),
                    _buildCard(
                      children: [
                        _buildField(
                          controller: _phoneController,
                          label: '手机号',
                          hint: '用于登录与找回账号',
                          icon: Icons.smartphone_outlined,
                          keyboardType: TextInputType.phone,
                          maxLength: 11,
                          errorText: _phoneError,
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 14),
                        _buildField(
                          controller: _emailController,
                          label: '邮箱（必填）',
                          hint: '接收注册验证码，用于找回账号',
                          icon: Icons.mail_outline,
                          keyboardType: TextInputType.emailAddress,
                          maxLength: 64,
                          errorText: _emailError,
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 14),
                        _buildField(
                          controller: _codeController,
                          label: '邮箱验证码',
                          hint: '6 位数字，10 分钟内有效',
                          icon: Icons.verified_outlined,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          onChanged: (_) => setState(() {}),
                          suffix: TextButton(
                            onPressed:
                                (_sendingCode || _resendCountdown > 0)
                                    ? null
                                    : _sendCode,
                            child: Text(
                              _sendingCode
                                  ? '发送中…'
                                  : _resendCountdown > 0
                                      ? '${_resendCountdown}s 后重发'
                                      : '获取验证码',
                              style: BodhiTypography.caption.copyWith(
                                color: (_sendingCode || _resendCountdown > 0)
                                    ? BodhiColors.inkFaint
                                    : BodhiColors.gold,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        _buildField(
                          controller: _nickController,
                          label: '用户名（可选）',
                          hint: '云备份将以用户名创建，不填默认同手机号',
                          icon: Icons.person_outline,
                          maxLength: 16,
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 14),
                        _buildField(
                          controller: _passController,
                          label: '密码',
                          hint: '至少 6 位',
                          icon: Icons.lock_outline,
                          obscure: _obscure,
                          maxLength: 32,
                          suffix: IconButton(
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              size: 18,
                              color: BodhiColors.inkFaint,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 14),
                        _buildField(
                          controller: _pass2Controller,
                          label: '确认密码',
                          hint: '再输入一次密码',
                          icon: Icons.lock_outline,
                          obscure: _obscure2,
                          maxLength: 32,
                          errorText:
                              passMismatch ? '两次输入的密码不一致' : null,
                          suffix: IconButton(
                            icon: Icon(
                              _obscure2
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              size: 18,
                              color: BodhiColors.inkFaint,
                            ),
                            onPressed: () =>
                                setState(() => _obscure2 = !_obscure2),
                          ),
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => _submit(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _buildSubmitButton(),
                    const SizedBox(height: 12),
                    Center(
                      child: TextButton(
                        onPressed: _busy ? null : _gotoLogin,
                        child: Text(
                          '已有账号？去登录',
                          style: BodhiTypography.caption.copyWith(
                            color: BodhiColors.gold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard({required List<Widget> children}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: BodhiColors.cardWhite,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: BodhiColors.inkBrown.withValues(alpha: 0.07),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    bool obscure = false,
    TextInputType? keyboardType,
    int? maxLength,
    String? errorText,
    Widget? suffix,
    List<TextInputFormatter>? inputFormatters,
    ValueChanged<String>? onChanged,
    ValueChanged<String>? onSubmitted,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 15, color: BodhiColors.gold),
            const SizedBox(width: 6),
            Text(label, style: BodhiTypography.groupTitle),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          maxLength: maxLength,
          inputFormatters: inputFormatters ??
              [LengthLimitingTextInputFormatter(maxLength ?? 64)],
          style: BodhiTypography.body,
          cursorColor: BodhiColors.gold,
          decoration: InputDecoration(
            counterText: '',
            hintText: hint,
            hintStyle: BodhiTypography.caption.copyWith(
              color: BodhiColors.inkFaint,
            ),
            errorText: errorText,
            filled: true,
            fillColor: BodhiColors.fieldBg,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: BodhiColors.gold),
            ),
            suffixIcon: suffix,
          ),
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
      ],
    );
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      height: 46,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: _canSubmit
              ? BodhiColors.goldGradient
              : const LinearGradient(
                  colors: [BodhiColors.divider, BodhiColors.divider]),
          borderRadius: BorderRadius.circular(23),
        ),
        child: TextButton(
          onPressed: _canSubmit ? _submit : null,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation(BodhiColors.paperLight),
                  ),
                )
              : Text(
                  '注 册',
                  style: BodhiTypography.rowLabel.copyWith(
                    color: _canSubmit
                        ? BodhiColors.paperLight
                        : BodhiColors.inkFaint,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
        ),
      ),
    );
  }
}
