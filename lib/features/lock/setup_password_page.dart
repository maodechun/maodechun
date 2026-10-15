import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/common.dart';
import '../../widgets/lotus_badge.dart';

/// 首次使用 · 设置启动密码
///
/// 产品要求：启动密码必须由用户自行设定（旧版是首次解锁时"输入即设定"，
/// 用户无感知、容易误设）。本页在首次进入主界面前强制引导：
///   - 输入两次 6 位数字，两次一致才能生效
///   - 设定后可在「设置 → 安全与锁定 → 修改启动密码」中更改
class SetupPasswordPage extends StatefulWidget {
  /// 设定成功回调（主壳层负责哈希与持久化）
  final Future<void> Function(String password) onSet;

  const SetupPasswordPage({super.key, required this.onSet});

  @override
  State<SetupPasswordPage> createState() => _SetupPasswordPageState();
}

class _SetupPasswordPageState extends State<SetupPasswordPage> {
  final _firstController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _obscureFirst = true;
  bool _obscureConfirm = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _firstController.addListener(_onChange);
    _confirmController.addListener(_onChange);
  }

  @override
  void dispose() {
    _firstController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _onChange() {
    // 任何输入变化都要刷新（一致性标记 / 按钮可用态 / 错误提示）
    if (mounted) setState(() {
      if (_error != null) _error = null;
    });
  }

  bool get _firstValid =>
      _firstController.text.length == 6 &&
      int.tryParse(_firstController.text) != null;

  bool get _matchValid =>
      _firstValid &&
      _confirmController.text == _firstController.text;

  bool get _canSubmit => _matchValid && !_saving;

  Future<void> _submit() async {
    if (!_canSubmit) {
      setState(() {
        if (!_firstValid) {
          _error = '请输入 6 位数字密码';
        } else if (!_matchValid) {
          _error = '两次输入的密码不一致，请重新确认';
        }
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSet(_firstController.text);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: BodhiColors.pageGradient),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              const SizedBox(height: 40),
              const LotusSeal(size: 72, showGlow: true),
              const SizedBox(height: 20),
              Text('设置启动密码', style: BodhiTypography.pageTitle),
              const SizedBox(height: 10),
              Text(
                '请设定 6 位数字密码，用于每次打开应用时保护您的密钥。\n'
                '密码由您自行设定并请牢记，应用不提供找回功能。',
                textAlign: TextAlign.center,
                style: BodhiTypography.caption.copyWith(height: 1.7),
              ),
              const SizedBox(height: 28),
              _buildField(
                controller: _firstController,
                label: '新密码（6 位数字）',
                obscure: _obscureFirst,
                toggleObscure: () =>
                    setState(() => _obscureFirst = !_obscureFirst),
              ),
              const SizedBox(height: 14),
              _buildField(
                controller: _confirmController,
                label: '确认新密码',
                obscure: _obscureConfirm,
                toggleObscure: () =>
                    setState(() => _obscureConfirm = !_obscureConfirm),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 24,
                child: _error == null
                    ? (_matchValid
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.check_circle_outline,
                                  size: 14, color: BodhiColors.moss),
                              const SizedBox(width: 6),
                              Text(
                                '两次输入一致',
                                style: BodhiTypography.caption.copyWith(
                                  color: BodhiColors.moss,
                                ),
                              ),
                            ],
                          )
                        : const SizedBox.shrink())
                    : Text(
                        _error!,
                        style: BodhiTypography.caption.copyWith(
                          color: BodhiColors.cinnabar,
                        ),
                      ),
              ),
              const SizedBox(height: 16),
              GoldButton(
                label: _saving ? '正在保存…' : '确认设定',
                // 保持可点：点按时给出明确错误（不一致 / 位数不足），
                // 避免禁用态让用户无从得知原因
                onPressed: _saving ? null : _submit,
                loading: _saving,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required bool obscure,
    required VoidCallback toggleObscure,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: BodhiTypography.fieldLabel),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          autofocus: label.startsWith('新密码'),
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          style: BodhiTypography.fieldText.copyWith(letterSpacing: 6),
          decoration: InputDecoration(
            filled: true,
            fillColor: BodhiColors.fieldBg,
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: GestureDetector(
                onTap: toggleObscure,
                child: Icon(
                  obscure
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                  color: BodhiColors.inkFaint,
                ),
              ),
            ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 40,
              minHeight: 20,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 13,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(
                color: BodhiColors.gold,
                width: 1.2,
              ),
            ),
          ),
          onSubmitted: (_) => _submit(),
        ),
      ],
    );
  }
}
