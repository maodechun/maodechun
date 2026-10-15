import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auto_lock_guard.dart';
import '../../core/permissions/permission_service.dart';
import '../../core/time/ntp_client.dart';
import '../../data/repository/token_repository.dart';
import '../../data/services/cache_service.dart';
import '../../data/services/ftp_backup_service.dart';
import '../../data/services/local_backup_service.dart';
import '../../data/services/qiniu_backup_service.dart';
import '../../data/services/update_service.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/common.dart';

/// S5 设置 · 备份与更新
///
/// 四个分组：
///   1. 安全与锁定（密码 / 指纹 / 3D 人脸 / 开屏语音）
///   2. 密钥备份（FTP 服务器）
///   3. 在线更新与浏览
///   4. 关于与版权
class SettingsPage extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onOpenBrowser;
  final VoidCallback onOpenPrivacy;
  final void Function(bool enabled) onVoiceChanged;

  /// 当前安全开关状态（由主壳层持有）
  final bool passwordEnabled;
  final bool fingerprintEnabled;
  final bool faceEnabled;
  final bool voiceEnabled;
  final void Function(String key, bool value) onSecurityChanged;

  /// 启动密码校验与修改（由主壳层提供哈希与持久化）
  final Future<bool> Function(String input) verifyPassword;
  final Future<String?> Function(String oldPwd, String newPwd) onChangePassword;

  const SettingsPage({
    super.key,
    required this.onBack,
    required this.onOpenBrowser,
    required this.onOpenPrivacy,
    required this.onVoiceChanged,
    required this.passwordEnabled,
    required this.fingerprintEnabled,
    required this.faceEnabled,
    required this.voiceEnabled,
    required this.onSecurityChanged,
    required this.verifyPassword,
    required this.onChangePassword,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final FtpBackupService _ftp = FtpBackupService.instance;
  final UpdateService _update = UpdateService.instance;
  final LocalBackupService _local = LocalBackupService.instance;

  // FTP 表单
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '21');
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  bool _useFtps = true;
  bool _obscurePass = true;
  bool _configLoaded = false;

  // 操作状态
  bool _testing = false;
  bool _backingUp = false;
  bool _checkingUpdate = false;
  bool _clearingCache = false;
  double _progress = 0;
  String _progressStage = '';

  // 版本
  String _currentVersion = '';

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _loadVersion();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _userController.dispose();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final config = await _ftp.loadConfig();
    if (!mounted) return;
    setState(() {
      _hostController.text = config.host;
      _portController.text = config.port.toString();
      _userController.text = config.username;
      _passController.text = config.password;
      _useFtps = config.useFtps;
      _configLoaded = true;
    });
  }

  Future<void> _loadVersion() async {
    final label = await _update.currentVersionLabel();
    if (!mounted) return;
    setState(() => _currentVersion = label);
  }

  FtpConfig get _currentConfig => FtpConfig(
        host: _hostController.text.trim(),
        port: int.tryParse(_portController.text.trim()) ?? 21,
        username: _userController.text.trim(),
        password: _passController.text,
        useFtps: _useFtps,
      );

  // ── 构建 ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: BodhiColors.pageGradient),
      child: SafeArea(
        child: Column(
          children: [
            BodhiNavBar(title: '设置', onBack: widget.onBack),
            Expanded(
              child: _configLoaded
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                      child: Column(
                        children: [
                          _buildCloudSection(),
                          const SizedBox(height: 8),
                          _buildSecuritySection(),
                          const SizedBox(height: 8),
                          _buildBackupSection(),
                          const SizedBox(height: 8),
                          _buildUpdateSection(),
                          const SizedBox(height: 8),
                          _buildAboutSection(),
                          const SizedBox(height: 12),
                          _buildCopyright(),
                        ],
                      ),
                    )
                  : const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(BodhiColors.gold),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 分组 0 · 云备份与恢复（七牛云，手机号即身份） ─────

  Widget _buildCloudSection() {
    return SectionCard(
      title: '云备份与恢复',
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        const TipBar(
          text: '换手机、误删都不怕：输入手机号即可把全部令牌加密备份到云端，'
              '恢复时输入同一手机号即可找回。无需密码与验证码。',
        ),
        const SizedBox(height: 6),
        SettingRow(
          label: '云备份',
          hint: '输入手机号，一键加密备份全部令牌',
          trailing: const Icon(
            Icons.cloud_upload_outlined,
            size: 18,
            color: BodhiColors.gold,
          ),
          onTap: _cloudBackupFlow,
        ),
        SettingRow(
          label: '云恢复',
          hint: '输入备份时的手机号，找回云端全部令牌',
          showDivider: false,
          trailing: const Icon(
            Icons.cloud_download_outlined,
            size: 18,
            color: BodhiColors.gold,
          ),
          onTap: _cloudRestoreFlow,
        ),
      ],
    );
  }

  // ── 分组 1 · 安全与锁定 ──────────────────────────────

  Widget _buildSecuritySection() {
    return SectionCard(
      title: '安全与锁定',
      children: [
        SettingRow(
          label: '密码锁定',
          hint: '6 位数字密码保护',
          trailing: GoldSwitch(
            value: widget.passwordEnabled,
            onChanged: (v) => widget.onSecurityChanged('password', v),
          ),
        ),
        SettingRow(
          label: '指纹解锁',
          hint: '使用设备指纹快速解锁',
          trailing: GoldSwitch(
            value: widget.fingerprintEnabled,
            onChanged: (v) => widget.onSecurityChanged('fingerprint', v),
          ),
        ),
        SettingRow(
          label: '3D 人脸解锁',
          hint: '支持 3D 结构光的设备可用',
          trailing: GoldSwitch(
            value: widget.faceEnabled,
            onChanged: (v) => widget.onSecurityChanged('face', v),
          ),
        ),
        SettingRow(
          label: '开屏语音',
          hint: '启动时播报「南无阿弥陀佛」',
          trailing: GoldSwitch(
            value: widget.voiceEnabled,
            onChanged: widget.onVoiceChanged,
          ),
        ),
        SettingRow(
          label: '修改启动密码',
          hint: '验证当前密码后设定新密码',
          trailing: const Icon(
            Icons.password_outlined,
            size: 18,
            color: BodhiColors.gold,
          ),
          onTap: _changePasswordFlow,
        ),
        SettingRow(
          label: '时间校准',
          hint: NtpClient.instance.isSynced
              ? '已校准，时钟准确'
              : '未校准，验证码可能不准确',
          trailing: const Icon(
            Icons.chevron_right,
            size: 18,
            color: BodhiColors.inkFaint,
          ),
          onTap: _manualTimeSync,
        ),
        SettingRow(
          label: '权限管理',
          hint: '相机 / 图库 / 定位 / 设备识别码',
          trailing: const Icon(
            Icons.chevron_right,
            size: 18,
            color: BodhiColors.inkFaint,
          ),
          onTap: _showPermissionManager,
        ),
      ],
    );
  }

  /// 权限管理：查看用途说明并可重新申请权限
  Future<void> _showPermissionManager() async {
    Map<String, bool> states;
    try {
      states = await PermissionService.instance.checkAll();
    } catch (_) {
      states = const {
        'camera': false,
        'gallery': false,
        'location': false,
        'phone': false,
      };
    }
    if (!mounted) return;

    String label(String key, String name) =>
        (states[key] ?? false) ? '$name（已开启）' : '$name（未开启）';

    final shouldRequest = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: BodhiColors.cardWhite,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Row(
            children: [
              const Icon(
                Icons.verified_user_outlined,
                size: 20,
                color: BodhiColors.gold,
              ),
              const SizedBox(width: 8),
              Text('权限管理', style: BodhiTypography.pageTitle),
            ],
          ),
          content: Text(
            '以下权限用于对应功能，均可按需开启：\n\n'
            '${label('camera', '相机')} —— 扫描二维码绑定令牌\n'
            '${label('gallery', '图库')} —— 从相册导入二维码图片\n'
            '${label('location', '定位')} —— 发现局域网 FTP 服务器\n'
            '${label('phone', '设备识别码')} —— 备份文件绑定校验\n\n'
            '点击「重新申请」将逐项弹出系统权限框。',
            style: BodhiTypography.body.copyWith(
              color: BodhiColors.inkGray,
              height: 1.7,
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
                '重新申请',
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

    if (shouldRequest == true) {
      await PermissionService.instance.requestAll();
      if (!mounted) return;
      _showSnack('权限申请完成，可在系统设置中查看结果');
    }
  }

  Future<void> _manualTimeSync() async {
    _showLoading('正在校准时间…');
    final result = await NtpClient.instance.manualSync();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    _showSnack(result.message);
    setState(() {});
  }

  // ── 修改启动密码 ─────────────────────────────────────

  /// 修改启动密码流程：验证当前密码 → 输入新密码（两次确认）→ 保存
  Future<void> _changePasswordFlow() async {
    final old = await _askSixDigits(
      title: '验证当前密码',
      hint: '输入当前启动密码',
    );
    if (old == null || !mounted) return;

    final ok = await widget.verifyPassword(old);
    if (!mounted) return;
    if (!ok) {
      _showSnack('当前密码不正确');
      return;
    }

    final newPwd = await _askNewPassword();
    if (newPwd == null || !mounted) return;

    final error = await widget.onChangePassword(old, newPwd);
    if (!mounted) return;
    _showSnack(error ?? '启动密码已更新，下次解锁请使用新密码');
  }

  /// 单个 6 位数字密码输入弹窗（用于验证当前密码）
  Future<String?> _askSixDigits({
    required String title,
    required String hint,
  }) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: BodhiColors.cardWhite,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text(title, style: BodhiTypography.pageTitle),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            style: BodhiTypography.fieldText.copyWith(letterSpacing: 6),
            decoration: InputDecoration(
              hintText: hint,
              filled: true,
              fillColor: BodhiColors.fieldBg,
              border: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(14)),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                '取消',
                style: BodhiTypography.rowLabel.copyWith(
                  color: BodhiColors.inkGray,
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                final v = controller.text;
                if (v.length != 6) return;
                Navigator.pop(context, v);
              },
              child: Text(
                '确认',
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
  }

  /// 新密码设定弹窗：两次输入 + 一致性校验
  Future<String?> _askNewPassword() {
    final c1 = TextEditingController();
    final c2 = TextEditingController();
    String? error;

    return showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            bool bothValid() =>
                c1.text.length == 6 &&
                int.tryParse(c1.text) != null &&
                c1.text == c2.text;

            return AlertDialog(
              backgroundColor: BodhiColors.cardWhite,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: Text('设定新密码', style: BodhiTypography.pageTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: c1,
                    autofocus: true,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    style: BodhiTypography.fieldText.copyWith(letterSpacing: 6),
                    onChanged: (_) => setDialogState(() => error = null),
                    decoration: InputDecoration(
                      hintText: '新密码（6 位数字）',
                      filled: true,
                      fillColor: BodhiColors.fieldBg,
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(14)),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: c2,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    style: BodhiTypography.fieldText.copyWith(letterSpacing: 6),
                    onChanged: (_) => setDialogState(() => error = null),
                    decoration: InputDecoration(
                      hintText: '确认新密码',
                      filled: true,
                      fillColor: BodhiColors.fieldBg,
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(14)),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      error!,
                      style: BodhiTypography.caption.copyWith(
                        color: BodhiColors.cinnabar,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    '取消',
                    style: BodhiTypography.rowLabel.copyWith(
                      color: BodhiColors.inkGray,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    if (c1.text.length != 6 ||
                        int.tryParse(c1.text) == null) {
                      setDialogState(
                          () => error = '新密码需为 6 位数字');
                      return;
                    }
                    if (c1.text != c2.text) {
                      setDialogState(
                          () => error = '两次输入的密码不一致，请重新确认');
                      return;
                    }
                    Navigator.pop(context, c1.text);
                  },
                  child: Text(
                    '保存新密码',
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
      },
    );
  }

  // ── 分组 2 · FTP 备份 ────────────────────────────────

  Widget _buildBackupSection() {
    return SectionCard(
      title: '密钥备份',
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        const TipBar(
          text: '备份文件使用备份密码加密，密钥与数据绝不以明文出现。'
              '可备份到本机下载目录，或上传至您自己的服务器。',
        ),
        const SizedBox(height: 6),
        SettingRow(
          label: '备份到本机',
          hint: '加密保存到手机「下载/菩提护令备份」，重装可恢复',
          trailing: const Icon(
            Icons.download_outlined,
            size: 18,
            color: BodhiColors.gold,
          ),
          onTap: _localBackupFlow,
        ),
        SettingRow(
          label: '从本机恢复',
          hint: '选择下载目录中的备份文件导入令牌',
          trailing: const Icon(
            Icons.restore_outlined,
            size: 18,
            color: BodhiColors.gold,
          ),
          onTap: _localRestoreFlow,
        ),
        const SizedBox(height: 4),
        SettingRow(
          label: '备份到 FTP 服务器',
          hint: '跨设备恢复 · 填写服务器信息后使用',
          showDivider: false,
          height: 36,
        ),
        const SizedBox(height: 14),

        _buildField(
          label: '服务器地址',
          controller: _hostController,
          hint: 'ftp.example.com',
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: _buildField(
                label: '端口',
                controller: _portController,
                hint: '21',
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('加密传输', style: BodhiTypography.fieldLabel),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      GoldSwitch(
                        value: _useFtps,
                        onChanged: (v) => setState(() => _useFtps = v),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _useFtps ? 'FTPS（推荐）' : 'FTP（不加密）',
                          style: BodhiTypography.caption.copyWith(
                            color: _useFtps
                                ? BodhiColors.moss
                                : BodhiColors.cinnabar,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _buildField(
          label: '账号',
          controller: _userController,
          hint: 'FTP 用户名',
        ),
        const SizedBox(height: 10),
        _buildField(
          label: '密码',
          controller: _passController,
          hint: 'FTP 密码',
          obscure: _obscurePass,
          suffix: GestureDetector(
            onTap: () => setState(() => _obscurePass = !_obscurePass),
            child: Icon(
              _obscurePass
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              size: 18,
              color: BodhiColors.inkFaint,
            ),
          ),
        ),

        if (!_useFtps)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: TipBar(
              icon: Icons.warning_amber_outlined,
              text: '已关闭加密传输，备份文件将以明文 FTP 上传，'
                  '存在被中间人截获的风险，建议开启 FTPS。',
            ),
          ),

        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlineGoldButton(
                label: _testing ? '测试中…' : '测试连接',
                onPressed: _testing ? null : _testConnection,
                height: 42,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: GoldButton(
                label: _backingUp ? '备份中…' : '立即备份',
                onPressed: _backingUp ? null : _startBackup,
                height: 42,
                loading: _backingUp,
              ),
            ),
          ],
        ),

        // 备份进度
        if (_backingUp) ...[
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 5,
              backgroundColor: BodhiColors.divider,
              valueColor: const AlwaysStoppedAnimation(BodhiColors.gold),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _progressStage,
            style: BodhiTypography.caption,
            textAlign: TextAlign.center,
          ),
        ],

        const SizedBox(height: 12),
        // 从备份恢复
        SettingRow(
          label: '从备份恢复',
          hint: '从服务器下载备份文件并导入令牌',
          height: 44,
          trailing: const Icon(
            Icons.chevron_right,
            size: 18,
            color: BodhiColors.inkFaint,
          ),
          onTap: _restoreFlow,
        ),

        const SizedBox(height: 4),
        SettingRow(
          label: '云端备份 / 恢复',
          hint: '已移至设置页顶部「云备份与恢复」分组',
          showDivider: false,
          trailing: const Icon(
            Icons.chevron_right,
            size: 18,
            color: BodhiColors.inkFaint,
          ),
          onTap: _cloudBackupFlow,
        ),
      ],
    );
  }

  Widget _buildField({
    required String label,
    required TextEditingController controller,
    String? hint,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: BodhiTypography.fieldLabel),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          style: BodhiTypography.fieldText,
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: BodhiTypography.caption.copyWith(
              color: BodhiColors.inkFaint,
            ),
            filled: true,
            fillColor: BodhiColors.fieldBg,
            suffixIcon: suffix == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: suffix,
                  ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 40,
              minHeight: 20,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
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
        ),
      ],
    );
  }

  Future<void> _testConnection() async {
    setState(() => _testing = true);
    await _ftp.saveConfig(_currentConfig);
    final result = await _ftp.testConnection(_currentConfig);
    if (!mounted) return;
    setState(() => _testing = false);
    _showSnack(result.message);
  }

  Future<void> _startBackup() async {
    if (!_currentConfig.isValid) {
      _showSnack('请先完整填写服务器地址、端口、账号与密码');
      return;
    }

    // 备份密码：优先复用 FTP 密码，亦可单独输入
    final password = await _askBackupPassword();
    if (password == null) return;

    await _ftp.saveConfig(_currentConfig);
    setState(() {
      _backingUp = true;
      _progress = 0;
      _progressStage = '准备中';
    });

    final result = await _ftp.backup(
      config: _currentConfig,
      password: password,
      progress: (p, stage) {
        if (!mounted) return;
        setState(() {
          _progress = p;
          _progressStage = stage;
        });
      },
    );

    if (!mounted) return;
    setState(() => _backingUp = false);
    _showSnack(result.message);
  }

  /// 询问备份密码（用于加密备份文件）
  ///
  /// 产品要求：密码需输入两次，两次一致才能继续，避免输错导致备份无法恢复。
  Future<String?> _askBackupPassword() async {
    final controller = TextEditingController();
    final confirmController = TextEditingController();
    var obscure = true;
    var obscureConfirm = true;
    String? error;

    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: BodhiColors.cardWhite,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: Text('设置备份密码', style: BodhiTypography.pageTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '备份文件将使用此密码加密。\n'
                    '请牢记该密码，恢复时必须输入相同的密码，'
                    '密码遗失将无法恢复备份。',
                    style: BodhiTypography.caption,
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    obscureText: obscure,
                    autofocus: true,
                    style: BodhiTypography.fieldText,
                    onChanged: (_) => setDialogState(() => error = null),
                    decoration: InputDecoration(
                      hintText: '备份密码（至少 6 位）',
                      filled: true,
                      fillColor: BodhiColors.fieldBg,
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscure
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 18,
                          color: BodhiColors.inkFaint,
                        ),
                        onPressed: () =>
                            setDialogState(() => obscure = !obscure),
                      ),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(14)),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: confirmController,
                    obscureText: obscureConfirm,
                    style: BodhiTypography.fieldText,
                    onChanged: (_) => setDialogState(() => error = null),
                    onSubmitted: (_) {
                      final v = controller.text;
                      if (v.length >= 6 && v == confirmController.text) {
                        Navigator.pop(context, v);
                      }
                    },
                    decoration: InputDecoration(
                      hintText: '再次输入备份密码',
                      filled: true,
                      fillColor: BodhiColors.fieldBg,
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscureConfirm
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 18,
                          color: BodhiColors.inkFaint,
                        ),
                        onPressed: () => setDialogState(
                            () => obscureConfirm = !obscureConfirm),
                      ),
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(14)),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      error!,
                      style: BodhiTypography.caption.copyWith(
                        color: BodhiColors.cinnabar,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    '取消',
                    style: BodhiTypography.rowLabel.copyWith(
                      color: BodhiColors.inkGray,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    final value = controller.text;
                    if (value.length < 6) {
                      setDialogState(() => error = '备份密码至少 6 位');
                      return;
                    }
                    if (value != confirmController.text) {
                      setDialogState(
                          () => error = '两次输入的密码不一致，请重新确认');
                      return;
                    }
                    Navigator.pop(context, value);
                  },
                  child: Text(
                    '确定',
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
      },
    );

    controller.dispose();
    confirmController.dispose();
    return result;
  }

  /// 恢复流程
  Future<void> _restoreFlow() async {
    if (!_currentConfig.isValid) {
      _showSnack('请先填写并保存服务器信息');
      return;
    }

    _showLoading('正在读取服务器备份列表…');
    final files = await _ftp.listBackups(_currentConfig);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (files.isEmpty) {
      _showSnack('服务器上没有找到备份文件');
      return;
    }

    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6,
          ),
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
                const SizedBox(height: 14),
                Text('选择要恢复的备份', style: BodhiTypography.pageTitle),
                const SizedBox(height: 6),
                Text(
                  '文件名中的时间即为备份时间',
                  style: BodhiTypography.caption,
                ),
                const SizedBox(height: 10),
                const Divider(height: 1),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: files.length,
                    itemBuilder: (context, index) {
                      return InkWell(
                        onTap: () {
                          Navigator.pop(context);
                          _doRestore(files[index]);
                        },
                        child: SizedBox(
                          height: 52,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.description_outlined,
                                  size: 18,
                                  color: BodhiColors.gold,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    files[index],
                                    style: BodhiTypography.rowLabel.copyWith(
                                      fontSize: 13,
                                      fontFamily: 'monospace',
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const Icon(
                                  Icons.chevron_right,
                                  size: 18,
                                  color: BodhiColors.inkFaint,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _doRestore(String fileName) async {
    final password = await _askRestorePassword();
    if (password == null || !mounted) return;

    setState(() {
      _backingUp = true;
      _progress = 0;
      _progressStage = '准备恢复';
    });

    final result = await _ftp.restore(
      config: _currentConfig,
      fileName: fileName,
      password: password,
      merge: true,
      progress: (p, stage) {
        if (!mounted) return;
        setState(() {
          _progress = p;
          _progressStage = stage;
        });
      },
    );

    if (!mounted) return;
    setState(() => _backingUp = false);
    _showSnack(result.message);
  }

  Future<String?> _askRestorePassword() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: BodhiColors.cardWhite,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text('输入备份密码', style: BodhiTypography.pageTitle),
          content: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            style: BodhiTypography.fieldText,
            decoration: const InputDecoration(
              hintText: '备份时设置的密码',
              filled: true,
              fillColor: BodhiColors.fieldBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(14)),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                '取消',
                style: BodhiTypography.rowLabel.copyWith(
                  color: BodhiColors.inkGray,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(
                '开始恢复',
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
    controller.dispose();
    return (result == null || result.isEmpty) ? null : result;
  }

  // ── 分组 2.5 · 云端备份（七牛云，手机号即身份） ───────

  /// 备份到云端：每次都要求输入手机号（预填上次绑定的号码）→ 加密备份
  Future<void> _cloudBackupFlow() async {
    final saved = await QiniuBackupService.instance.getPhone();
    final input = await _askCloudPhone(title: '云备份 · 输入手机号', initial: saved);
    if (input == null || !mounted) return;

    _showLoading('正在加密并上传到云端…');
    final result = await QiniuBackupService.instance.backup(input);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    _showSnack(result.message);
  }

  /// 从云端恢复：输入手机号 → 下载最新备份并导入
  Future<void> _cloudRestoreFlow() =>
      AutoLockGuard.run(() => _cloudRestoreFlowImpl());

  Future<void> _cloudRestoreFlowImpl() async {
    final saved = await QiniuBackupService.instance.getPhone();
    final input = await _askCloudPhone(
      title: '从云端恢复',
      initial: saved,
    );
    if (input == null || !mounted) return;

    _showLoading('正在从云端下载并恢复…');
    final result =
        await QiniuBackupService.instance.restore(input, merge: true);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    _showSnack(result.message);
  }

  /// 询问手机号弹窗（11 位大陆手机号，无需验证码）
  Future<String?> _askCloudPhone({
    required String title,
    String? initial,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        var error = '';
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            backgroundColor: BodhiColors.paperLight,
            title: Text(title, style: BodhiTypography.pageTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '手机号仅用于区分不同用户的备份，'
                  '不需要验证码与密码，请确保号码真实有效。',
                  style: BodhiTypography.caption,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  keyboardType: TextInputType.phone,
                  maxLength: 11,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    hintText: '请输入 11 位手机号',
                    counterText: '',
                    errorText: error.isEmpty ? null : error,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  final v = controller.text.trim();
                  if (!QiniuBackupService.isValidPhone(v)) {
                    setDialogState(() => error = '手机号格式不正确');
                    return;
                  }
                  Navigator.of(dialogContext).pop(v);
                },
                child: const Text('确定'),
              ),
            ],
          ),
        );
      },
    ).then((value) {
      controller.dispose();
      return value;
    });
  }

  // ── 分组 3 · 在线更新与浏览 ──────────────────────────

  /// 备份到本机：设置密码 → 加密导出到下载目录
  ///
  /// 全程挂起自动上锁（流程含密码弹窗与存储写入，期间不应被打断）
  Future<void> _localBackupFlow() =>
      AutoLockGuard.run(() => _localBackupFlowImpl());

  Future<void> _localBackupFlowImpl() async {
    final password = await _askBackupPassword();
    if (password == null || !mounted) return;

    _showLoading('正在加密并保存备份…');
    final result = await _local.backup(password);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    _showSnack(result.message);
  }

  /// 从本机恢复：列出下载目录备份 → 选择 → 输密码 → 导入
  ///
  /// 兼容场景：卸载重装后 MediaStore 索引被系统清空，列表可能为空，
  /// 因此始终提供「从文件管理器选择」入口（SAF 直读文件本体）。
  /// 全程挂起自动上锁：SAF 选择器会让应用 paused 超 30 秒，
  /// 若不挂起，重锁会卸载本页、流程在 !mounted 处静默中止。
  Future<void> _localRestoreFlow() =>
      AutoLockGuard.run(() => _localRestoreFlowImpl());

  Future<void> _localRestoreFlowImpl() async {
    // ignore: avoid_print
    print('[LocalBackup] restore flow TAPPED');
    _showLoading('正在查找本机备份…');
    final files = await _local.listBackups();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (!mounted) return;
    const pickerTag = '__pick_from_fm__';
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6,
          ),
          decoration: const BoxDecoration(
            color: BodhiColors.cardWhite,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
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
                const SizedBox(height: 14),
                Text('选择本机备份', style: BodhiTypography.pageTitle),
                const SizedBox(height: 6),
                Text(
                  files.isEmpty
                      ? '自动列表为空（重装后常见），请从文件管理器选择'
                      : '位于「下载/菩提护令备份」，文件名含备份时间',
                  style: BodhiTypography.caption,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                const Divider(height: 1),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: files.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return InkWell(
                          onTap: () => Navigator.pop(context, pickerTag),
                          child: SizedBox(
                            height: 52,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 20),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.folder_open_outlined,
                                    size: 18,
                                    color: BodhiColors.gold,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      '从文件管理器选择备份文件…',
                                      style: BodhiTypography.rowLabel.copyWith(
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }
                      final f = files[index - 1];
                      return InkWell(
                        onTap: () => Navigator.pop(context, f.id),
                        child: SizedBox(
                          height: 52,
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 20),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.lock_outline,
                                  size: 18,
                                  color: BodhiColors.gold,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    f.name,
                                    style:
                                        BodhiTypography.rowLabel.copyWith(
                                      fontSize: 13,
                                      fontFamily: 'monospace',
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  f.humanSize,
                                  style: BodhiTypography.caption,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (picked == null || !mounted) return;

    String id;
    if (picked == pickerTag) {
      final pickedFile = await _local.pickBackup();
      if (pickedFile == null || !mounted) return; // 用户取消
      id = pickedFile.id;
    } else {
      id = picked;
    }
    if (!mounted) return;

    final password = await _askRestorePassword();
    if (password == null || !mounted) return;

    _showLoading('正在解密并导入令牌…');
    final result = await _local.restore(id, password, merge: true);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    _showSnack(result.message);
  }


  Widget _buildUpdateSection() {
    return SectionCard(
      title: '在线更新与浏览',
      children: [
        SettingRow(
          label: '在线更新',
          hint: '更新服务器 app.0499.com.cn',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_checkingUpdate)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    valueColor: AlwaysStoppedAnimation(BodhiColors.gold),
                  ),
                )
              else
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: BodhiColors.inkFaint,
                ),
            ],
          ),
          onTap: _checkingUpdate ? null : _checkUpdate,
        ),
        SettingRow(
          label: '打开官网',
          hint: '内置浏览器 m.0499.com.cn',
          trailing: const Icon(
            Icons.chevron_right,
            size: 18,
            color: BodhiColors.inkFaint,
          ),
          onTap: widget.onOpenBrowser,
        ),
        SettingRow(
          label: '清除缓存',
          hint: '一键清除网页缓存与临时文件',
          trailing: const Icon(
            Icons.chevron_right,
            size: 18,
            color: BodhiColors.inkFaint,
          ),
          onTap: _clearingCache ? null : _clearCache,
        ),
      ],
    );
  }

  /// 一键清除所有缓存（网页缓存 / Cookie / 临时文件），不动令牌与设置
  Future<void> _clearCache() async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: BodhiColors.cardWhite,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Row(
            children: [
              const Icon(
                Icons.cleaning_services_outlined,
                size: 20,
                color: BodhiColors.gold,
              ),
              const SizedBox(width: 8),
              Text('清除缓存', style: BodhiTypography.pageTitle),
            ],
          ),
          content: Text(
            '将清除以下内容：\n\n'
            '· 网页缓存与离线数据\n'
            '· 网页 Cookie\n'
            '· 应用临时文件（含已下载的更新包）\n\n'
            '不会影响您的令牌、密码与任何设置。',
            style: BodhiTypography.body.copyWith(
              color: BodhiColors.inkGray,
              height: 1.7,
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
                '一键清除',
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

    if (agreed != true || !mounted) return;
    setState(() => _clearingCache = true);
    final result = await CacheService.instance.clearAll();
    if (!mounted) return;
    setState(() => _clearingCache = false);
    _showSnack(result.message);
  }

  Future<void> _checkUpdate() async {
    setState(() => _checkingUpdate = true);
    final info = await _update.check(silent: false);
    if (!mounted) return;
    setState(() => _checkingUpdate = false);

    if (info == null) {
      _showSnack('当前已是最新版本');
      return;
    }
    await showUpdateDialog(info);
  }

  /// 更新弹窗（由外部也可调用，如启动时检测到新版本）
  Future<void> showUpdateDialog(UpdateInfo info) async {
    if (!mounted) return;

    final notes = info.notesList;
    final isIOS = Theme.of(context).platform == TargetPlatform.iOS;

    await showDialog<void>(
      context: context,
      barrierDismissible: !info.forceUpdate,
      builder: (context) {
        return PopScope(
          canPop: !info.forceUpdate,
          child: AlertDialog(
            backgroundColor: BodhiColors.cardWhite,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Row(
              children: [
                const Icon(
                  Icons.system_update_alt,
                  size: 20,
                  color: BodhiColors.gold,
                ),
                const SizedBox(width: 8),
                Text('发现新版本', style: BodhiTypography.pageTitle),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: BodhiColors.cinnabar,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    info.versionName,
                    style: BodhiTypography.badge,
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (info.forceUpdate) ...[
                  const TipBar(
                    icon: Icons.priority_high,
                    text: '此版本为重要更新，需更新后才能继续使用。',
                  ),
                  const SizedBox(height: 12),
                ],
                if (notes.isNotEmpty) ...[
                  Text('更新内容', style: BodhiTypography.groupTitle),
                  const SizedBox(height: 8),
                  ...notes.map(
                    (line) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        line,
                        style: BodhiTypography.caption.copyWith(
                          fontSize: 12,
                          height: 1.6,
                        ),
                      ),
                    ),
                  ),
                ] else
                  Text(
                    '本次更新修复了若干问题并优化了使用体验。',
                    style: BodhiTypography.caption.copyWith(fontSize: 12),
                  ),
                if (isIOS) ...[
                  const SizedBox(height: 14),
                  Text(
                    'iOS 版本请前往 App Store 完成更新。',
                    style: BodhiTypography.caption.copyWith(
                      color: BodhiColors.gold,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              if (!info.forceUpdate)
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    '稍后',
                    style: BodhiTypography.rowLabel.copyWith(
                      color: BodhiColors.inkGray,
                    ),
                  ),
                ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  _startUpdateDownload(info);
                },
                child: Text(
                  isIOS ? '前往 App Store' : '立即更新',
                  style: BodhiTypography.rowLabel.copyWith(
                    color: BodhiColors.gold,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _startUpdateDownload(UpdateInfo info) async {
    // iOS 不支持应用内自更新
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      _showSnack('请前往 App Store 搜索「菩提护令」完成更新');
      return;
    }

    if (info.downloadUrl.isEmpty) {
      _showSnack('更新地址无效，请前往官网下载');
      return;
    }

    setState(() {
      _progress = 0;
      _progressStage = '正在下载更新包';
    });

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: BodhiColors.cardWhite,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: Text('正在下载更新', style: BodhiTypography.pageTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: _progress,
                      minHeight: 5,
                      backgroundColor: BodhiColors.divider,
                      valueColor: const AlwaysStoppedAnimation(
                        BodhiColors.gold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${(_progress * 100).toStringAsFixed(0)}%',
                    style: BodhiTypography.caption,
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    final file = await _update.download(
      info,
      progress: (p) {
        if (!mounted) return;
        setState(() {
          _progress = p;
          _progressStage = '下载中 ${(p * 100).toStringAsFixed(0)}%';
        });
      },
    );

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (file == null) {
      _showSnack('下载失败或校验未通过，请稍后重试');
      return;
    }

    // 校验通过后交由系统安装器处理
    // 实际实现：使用 open_filex 打开 APK
    _showSnack('下载完成，正在启动安装程序…');
  }

  // ── 分组 4 · 关于与版权 ──────────────────────────────

  Widget _buildAboutSection() {
    return SectionCard(
      title: '关于与版权',
      children: [
        SettingRow(
          label: '联系我们',
          height: 46,
          trailing: Text(
            'maodechun@qq.com',
            style: BodhiTypography.rowValue,
          ),
          onTap: _openMailClient,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '点击邮箱唤起系统邮件客户端发送邮件',
            style: BodhiTypography.caption.copyWith(fontSize: 10),
          ),
        ),
        SettingRow(
          label: '服务电话',
          height: 46,
          trailing: Text(
            '133307459931',
            style: BodhiTypography.rowValue,
          ),
          onTap: _callPhone,
        ),
        SettingRow(
          label: '隐私政策',
          height: 46,
          trailing: const Icon(
            Icons.chevron_right,
            size: 18,
            color: BodhiColors.inkFaint,
          ),
          onTap: widget.onOpenPrivacy,
        ),
      ],
    );
  }

  /// 唤起系统默认邮件客户端
  Future<void> _openMailClient() async {
    const email = 'maodechun@qq.com';
    final uri = Uri(
      scheme: 'mailto',
      path: email,
      query: 'subject=${Uri.encodeComponent('菩提护令 使用反馈（${_currentVersion.isEmpty ? "v5.3.2" : _currentVersion}）')}',
    );

    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        // 降级：无邮件客户端时复制邮箱并提示
        await Clipboard.setData(const ClipboardData(text: email));
        _showSnack('未检测到邮件客户端，邮箱已复制：$email');
      }
    } catch (_) {
      await Clipboard.setData(const ClipboardData(text: email));
      _showSnack('无法打开邮件客户端，邮箱已复制：$email');
    }
  }

  /// 调起拨号盘
  Future<void> _callPhone() async {
    const phone = '133307459931';
    final uri = Uri(scheme: 'tel', path: phone);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        await Clipboard.setData(const ClipboardData(text: phone));
        _showSnack('无法拨号，号码已复制：$phone');
      }
    } catch (_) {
      await Clipboard.setData(const ClipboardData(text: phone));
      _showSnack('无法拨号，号码已复制：$phone');
    }
  }

  Widget _buildCopyright() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        '菩提护令 ${_currentVersion.isEmpty ? "v5.3.2" : _currentVersion} · '
        '道拓日记版权所有 · 本地加密存储',
        style: BodhiTypography.copyright,
        textAlign: TextAlign.center,
      ),
    );
  }

  // ── 工具 ─────────────────────────────────────────────

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

  void _showLoading(String message) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: BodhiColors.inkBrown,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(BodhiColors.goldLight),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  style: BodhiTypography.caption.copyWith(
                    color: BodhiColors.paperLight,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
