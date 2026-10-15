import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/security/clipboard_guard.dart';
import '../../core/time/ntp_client.dart';
import '../../core/totp/generator.dart';
import '../../data/models/token.dart';
import '../../data/repository/token_repository.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/common.dart';
import '../../widgets/countdown_ring.dart';
import '../../widgets/lotus_badge.dart';

/// S4 令牌列表
///
/// 每秒重绘验证码与倒计时环；支持搜索、长按菜单、FAB 添加。
///
/// 底部导航由主壳层（AppShell）统一管理，本页只负责令牌内容。
class TokenListPage extends StatefulWidget {
  final VoidCallback onAddToken;
  final void Function(Token token) onExport;
  final VoidCallback onOpenSettings;

  const TokenListPage({
    super.key,
    required this.onAddToken,
    required this.onExport,
    required this.onOpenSettings,
  });

  @override
  State<TokenListPage> createState() => _TokenListPageState();
}

class _TokenListPageState extends State<TokenListPage> {
  final TokenRepository _repo = TokenRepository.instance;
  final TextEditingController _searchController = TextEditingController();

  Timer? _ticker;
  DateTime _now = DateTime.now();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _repo.addListener(_onRepoChanged);
    _searchController.addListener(_onSearchChanged);
    _startTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _repo.removeListener(_onRepoChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onRepoChanged() {
    if (mounted) setState(() {});
  }

  void _onSearchChanged() {
    final q = _searchController.text.trim().toLowerCase();
    if (q != _query) {
      setState(() => _query = q);
    }
  }

  /// 每秒刷新，驱动验证码与倒计时环
  void _startTicker() {
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      setState(() => _now = NtpClient.instance.now);
    });
  }

  /// 过滤后的令牌
  List<Token> get _filtered {
    if (_query.isEmpty) return _repo.tokens;
    return _repo.tokens.where((t) {
      return t.issuer.toLowerCase().contains(_query) ||
          t.account.toLowerCase().contains(_query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: BodhiColors.pageGradient),
      child: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              children: [
                _buildHeader(),
                _buildSearchBar(),
                const SizedBox(height: 8),
                Expanded(
                  child: _repo.tokens.isEmpty
                      ? _buildEmptyState()
                      : _buildList(),
                ),
              ],
            ),
            // 悬浮添加按钮
            Positioned(
              right: 20,
              bottom: 20,
              child: _buildFab(),
            ),
          ],
        ),
      ),
    );
  }

  // ── 顶部 ─────────────────────────────────────────────

  Widget _buildHeader() {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            const LotusBadge(size: 24),
            const SizedBox(width: 10),
            Text(
              '菩提护令',
              style: BodhiTypography.pageTitle.copyWith(fontSize: 18),
            ),
            const Spacer(),
            // 时间未校准提示
            if (!NtpClient.instance.isSynced)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Tooltip(
                  message: '时间未校准，验证码可能不准确',
                  child: Icon(
                    Icons.schedule_outlined,
                    size: 18,
                    color: BodhiColors.inkFaint,
                  ),
                ),
              ),
            GestureDetector(
              onTap: widget.onOpenSettings,
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(
                  Icons.settings_outlined,
                  size: 22,
                  color: BodhiColors.inkBrown,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          color: BodhiColors.cardWhite,
          borderRadius: BorderRadius.circular(21),
          border: Border.all(color: BodhiColors.divider),
        ),
        child: Row(
          children: [
            const SizedBox(width: 14),
            const Icon(
              Icons.search,
              size: 18,
              color: BodhiColors.inkFaint,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchController,
                style: BodhiTypography.rowLabel.copyWith(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '搜索服务或账号',
                  hintStyle: BodhiTypography.caption.copyWith(
                    fontSize: 13,
                    color: BodhiColors.inkFaint,
                  ),
                ),
              ),
            ),
            if (_query.isNotEmpty)
              GestureDetector(
                onTap: () => _searchController.clear(),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(
                    Icons.close,
                    size: 16,
                    color: BodhiColors.inkFaint,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── 空态 ─────────────────────────────────────────────

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Opacity(
            opacity: 0.35,
            child: const LotusBadge(size: 72, strokeWidth: 1.2),
          ),
          const SizedBox(height: 20),
          Text('暂无令牌', style: BodhiTypography.pageTitle),
          const SizedBox(height: 8),
          Text(
            '点击右下角按钮，扫描二维码或手动输入密钥',
            style: BodhiTypography.caption,
          ),
        ],
      ),
    );
  }

  // ── 列表 ─────────────────────────────────────────────

  Widget _buildList() {
    final items = _filtered;

    if (items.isEmpty) {
      return Center(
        child: Text(
          '未找到匹配的令牌',
          style: BodhiTypography.caption,
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 100),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        return _buildTokenCard(items[index]);
      },
    );
  }

  Widget _buildTokenCard(Token token) {
    final code = _repo.generateCode(token, now: _now);
    final remaining = TotpGenerator.remainingSeconds(
      period: token.period,
      now: _now,
    );
    final progress = TotpGenerator.remainingRatio(
      period: token.period,
      now: _now,
    );
    final urgent = remaining <= 5;

    return GestureDetector(
      onTap: () => _copyCode(token, code),
      onLongPress: () => _showTokenMenu(token),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: BodhiColors.cardWhite,
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: BodhiColors.inkBrown.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部：色点 + 服务名 + 倒计时环
            Row(
              children: [
                TokenDot(colorIndex: token.colorTag, size: 10),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    token.title,
                    style: BodhiTypography.tokenIssuer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // 非标准参数标记
                if (token.isNonStandard)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: BodhiColors.tipBg,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${token.algorithm} · ${token.digits}位',
                        style: BodhiTypography.caption.copyWith(
                          fontSize: 9,
                          color: BodhiColors.tipText,
                        ),
                      ),
                    ),
                  ),
                TokenCountdownRing(
                  progress: progress,
                  remainingSeconds: remaining,
                ),
              ],
            ),

            // 账号
            if (token.subtitle.isNotEmpty) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 18),
                child: Text(
                  token.subtitle,
                  style: BodhiTypography.tokenAccount,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],

            const SizedBox(height: 10),

            // 验证码
            Padding(
              padding: const EdgeInsets.only(left: 18),
              child: Row(
                children: [
                  Text(
                    code == null ? '------' : _formatCode(code),
                    style: urgent
                        ? BodhiTypography.tokenCodeUrgent
                        : BodhiTypography.tokenCode,
                  ),
                  const SizedBox(width: 10),
                  if (code != null)
                    Icon(
                      Icons.copy_rounded,
                      size: 15,
                      color: BodhiColors.inkFaint,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 验证码按 3+3 分组显示
  String _formatCode(String code) {
    if (code.length == 6) {
      return '${code.substring(0, 3)} ${code.substring(3)}';
    }
    if (code.length == 8) {
      return '${code.substring(0, 4)} ${code.substring(4)}';
    }
    return code;
  }

  // ── 交互 ─────────────────────────────────────────────

  /// 点击复制验证码
  Future<void> _copyCode(Token token, String? code) async {
    if (code == null) {
      _showSnack('验证码生成失败，请检查密钥');
      return;
    }
    await ClipboardGuard.copySensitive(code, autoClearSeconds: 30);
    await HapticFeedback.lightImpact();
    _showSnack('验证码已复制（30 秒后自动清除）');
  }

  /// 长按菜单
  void _showTokenMenu(Token token) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: BodhiColors.cardWhite,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: BodhiColors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      TokenDot(colorIndex: token.colorTag),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          token.title,
                          style: BodhiTypography.tokenIssuer,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                _menuItem(
                  icon: Icons.qr_code_2,
                  label: '导出密钥',
                  onTap: () {
                    Navigator.pop(context);
                    widget.onExport(token);
                  },
                ),
                _menuItem(
                  icon: Icons.edit_outlined,
                  label: '编辑信息',
                  onTap: () {
                    Navigator.pop(context);
                    _editToken(token);
                  },
                ),
                _menuItem(
                  icon: Icons.delete_outline,
                  label: '删除令牌',
                  danger: true,
                  onTap: () {
                    Navigator.pop(context);
                    _confirmDelete(token);
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _menuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    final color = danger ? BodhiColors.cinnabar : BodhiColors.inkBrown;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 12),
              Text(
                label,
                style: BodhiTypography.rowLabel.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 编辑令牌信息
  Future<void> _editToken(Token token) async {
    final issuerController = TextEditingController(text: token.issuer);
    final accountController = TextEditingController(text: token.account);

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: BodhiColors.cardWhite,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text('编辑令牌', style: BodhiTypography.pageTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: issuerController,
                decoration: const InputDecoration(
                  labelText: '服务名称',
                  filled: true,
                  fillColor: BodhiColors.fieldBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                    borderSide: BorderSide.none,
                  ),
                ),
                style: BodhiTypography.fieldText,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: accountController,
                decoration: const InputDecoration(
                  labelText: '账号',
                  filled: true,
                  fillColor: BodhiColors.fieldBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                    borderSide: BorderSide.none,
                  ),
                ),
                style: BodhiTypography.fieldText,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                '取消',
                style: BodhiTypography.rowLabel.copyWith(
                  color: BodhiColors.inkGray,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                '保存',
                style: BodhiTypography.rowLabel.copyWith(
                  color: BodhiColors.gold,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (saved == true) {
      await _repo.updateToken(
        token.id,
        issuer: issuerController.text.trim(),
        account: accountController.text.trim(),
      );
      if (mounted) _showSnack('已保存');
    }

    issuerController.dispose();
    accountController.dispose();
  }

  /// 删除确认
  Future<void> _confirmDelete(Token token) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: BodhiColors.cardWhite,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text('删除令牌', style: BodhiTypography.pageTitle),
          content: Text(
            '确定要删除「${token.title}」吗？\n\n'
            '删除后该令牌的密钥将永久丢失，'
            '若未做备份将无法恢复，可能导致您无法登录对应账号。',
            style: BodhiTypography.body.copyWith(
              color: BodhiColors.inkGray,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                '取消',
                style: BodhiTypography.rowLabel.copyWith(
                  color: BodhiColors.inkGray,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                '确认删除',
                style: BodhiTypography.rowLabel.copyWith(
                  color: BodhiColors.cinnabar,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      await _repo.deleteToken(token.id);
      if (mounted) _showSnack('已删除');
    }
  }

  // ── FAB ──────────────────────────────────────────────

  Widget _buildFab() {
    return GestureDetector(
      onTap: widget.onAddToken,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          gradient: BodhiColors.goldGradient,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: BodhiColors.gold.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.qr_code_scanner,
              size: 18,
              color: BodhiColors.paperLight,
            ),
            const SizedBox(width: 8),
            Text(
              '扫码 / 添加令牌',
              style: BodhiTypography.buttonPrimary.copyWith(fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

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
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
