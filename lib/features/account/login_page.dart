import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/common.dart';
import 'account_api.dart';
import 'account_session.dart';

/// 用户登录页
class LoginPage extends StatefulWidget {
  /// 登录成功回调（已刷新 AccountSession）
  final VoidCallback? onSuccess;

  const LoginPage({super.key, this.onSuccess});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _phoneController = TextEditingController();
  final _passController = TextEditingController();
  bool _obscure = true;
  bool _busy = false;

  @override
  void dispose() {
    _phoneController.dispose();
    _passController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_busy &&
      _phoneController.text.trim().length >= 5 &&
      _passController.text.length >= 6;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    _hideKeyboard();
    setState(() => _busy = true);

    try {
      final result = await AccountApi.instance.login(
        phone: _phoneController.text.trim(),
        password: _passController.text,
      );
      await AccountSession.instance.save(
        token: result.token,
        phone: result.phone,
        nickname: result.nickname,
        createdAt: result.createdAt,
      );
      if (!mounted) return;
      _showSnack('登录成功，欢迎回来');
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
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: BodhiColors.pageGradient),
      child: SafeArea(
        child: Column(
          children: [
            BodhiNavBar(
              title: '用户登录',
              onBack: _busy ? null : () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const TipBar(
                      text: '登录后可同步使用云备份等功能；'
                          '密码仅在登录时使用，不会保存在本机。',
                    ),
                    const SizedBox(height: 16),
                    _buildCard(
                      children: [
                        _buildField(
                          controller: _phoneController,
                          label: '手机号',
                          hint: '请输入注册时的手机号',
                          icon: Icons.smartphone_outlined,
                          keyboardType: TextInputType.phone,
                          maxLength: 15,
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 14),
                        _buildField(
                          controller: _passController,
                          label: '密码',
                          hint: '请输入密码',
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
                          onSubmitted: (_) => _submit(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _buildSubmitButton(),
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
              : const LinearGradient(colors: [BodhiColors.divider, BodhiColors.divider]),
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
                  '登 录',
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
