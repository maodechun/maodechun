import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/common.dart';
import 'account_api.dart';
import 'account_session.dart';
import 'login_page.dart';

/// 用户注册页
///
/// 手机号 + 密码注册，注册成功即自动登录。
class RegisterPage extends StatefulWidget {
  final VoidCallback? onSuccess;

  const RegisterPage({super.key, this.onSuccess});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _phoneController = TextEditingController();
  final _nickController = TextEditingController();
  final _passController = TextEditingController();
  final _pass2Controller = TextEditingController();
  bool _obscure = true;
  bool _obscure2 = true;
  bool _busy = false;

  @override
  void dispose() {
    _phoneController.dispose();
    _nickController.dispose();
    _passController.dispose();
    _pass2Controller.dispose();
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

  bool get _canSubmit =>
      !_busy &&
      _phoneError == null &&
      _phoneController.text.trim().isNotEmpty &&
      _passController.text.length >= 6 &&
      _passController.text == _pass2Controller.text;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    _hideKeyboard();
    setState(() => _busy = true);

    try {
      final result = await AccountApi.instance.register(
        phone: _phoneController.text.trim(),
        password: _passController.text,
        nickname: _nickController.text.trim(),
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
                      text: '注册只需手机号与密码。密码经服务端加密保存，'
                          '任何人（包括开发者）都无法看到明文。',
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
                          controller: _nickController,
                          label: '昵称（可选）',
                          hint: '不填则默认与手机号相同',
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
          inputFormatters: [
            LengthLimitingTextInputFormatter(maxLength ?? 64),
          ],
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
