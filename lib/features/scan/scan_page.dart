import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';

import '../../core/permissions/permission_service.dart';
import '../../core/totp/uri_parser.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/common.dart';

/// S2 扫描绑定密钥
///
/// ═══════════════════════════════════════════════════════
/// 扫码引擎说明（v5.2.0 重写，务必保持）
/// ═══════════════════════════════════════════════════════
/// 相机预览与解码全部在原生层完成（ScanEngine.kt：CameraX + zxing）：
///   - AndroidView(viewType: 'bodhi/scan_view') 嵌入预览
///   - 视图通道 bodhi/scan_view_<id>：onReady / onDetected / onError
///   - 静态通道 bodhi/scan：decodeFromFile（相册识别）
/// 弃用 mobile_scanner 的原因：其 ML Kit 引擎在无 Google 服务的国产手机上
/// 稳定报 "Internal error when executing ML Kit tasks"，本地 barhopper
/// 模式实测同样失败。zxing 纯 Java、零 GMS 依赖、所有设备离线可用。
///
/// 不变量（任何改动不得破坏）：
///   1. 进入页面只读权限状态，绝不直接初始化相机
///   2. 相机启动失败（onError）降级为手动输入，绝不崩溃
///   3. 权限被拒后展示引导页，提供「前往系统设置」与「手动输入」两条出路
///   4. 识别到非令牌二维码时 reset 继续扫，不退出
/// 权限申请时机（合规要求）：
///   进入页面 → 展示用途说明 → 用户点击同意 → 调系统权限
/// ═══════════════════════════════════════════════════════
class ScanPage extends StatefulWidget {
  /// 扫码 / 相册 / 手动输入成功后的回调
  ///
  /// 使用列表而非单条：Google Authenticator「转移账号」导出的二维码
  /// 一次可携带数十个账号，需要批量导入。
  ///
  /// [keepScanning] 为 true 表示「这只是其中一张二维码，后面还有」——
  /// 调用方应当导入后**留在扫码页**，让用户接着扫下一张，
  /// 而不是跳回令牌列表（否则用户会以为已经全部导入完成）。
  ///
  /// 返回 Future：扫码页要等落库完成后再给出「请继续扫下一张」的提示，
  /// 保证这条提示是最后一条（否则会被调用方的「导入成功」提示覆盖）。
  final Future<void> Function(List<OtpAuthData> data, {bool? keepScanning})
      onBound;

  /// 返回回调（为空时退回 Navigator）
  final VoidCallback? onBack;

  const ScanPage({super.key, required this.onBound, this.onBack});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

/// 页面阶段
enum _ScanStage {
  /// 首次进入：展示用途说明，等待用户同意后再申请权限
  intro,

  /// 已授权，正常扫码
  scanning,

  /// 相机初始化失败，降级手动输入
  cameraFailed,

  /// 权限被拒，展示引导
  denied,

  /// 手动输入密钥
  manualInput,
}

class _ScanPageState extends State<ScanPage> {
  _ScanStage _stage = _ScanStage.intro;

  // ── 原生扫码视图通道 ─────────────────────────────────
  MethodChannel? _scanViewChannel;
  bool _cameraReady = false;
  bool _cameraError = false;
  /// null = 原生尚未上报；false = 本机无补光灯，隐藏按钮
  bool? _hasTorch;

  /// 防止重复触发绑定
  bool _handlingResult = false;

  /// 已成功导入的分批二维码原始内容
  ///
  /// Google 账号较多时会拆成多张二维码。多张场景下扫完一张要继续留在
  /// 扫码页，此时必须重置原生检测器，否则同一张会被反复识别、重复导入。
  final Set<String> _handledPayloads = <String>{};

  /// 相册解码进行中（防重入）
  bool _picking = false;

  final TextEditingController _manualController = TextEditingController();
  String? _manualError;
  bool _manualValid = false;

  @override
  void initState() {
    super.initState();
    _manualController.addListener(_onManualChanged);
    // 进入页面只检查权限状态，**不申请、不初始化相机**
    _checkPermissionOnEnter();
  }

  @override
  void dispose() {
    _manualController.removeListener(_onManualChanged);
    _manualController.dispose();
    _scanViewChannel?.setMethodCallHandler(null);
    super.dispose();
  }

  // ══════════════════════════════════════════════════════
  //  原生扫码视图回调
  // ══════════════════════════════════════════════════════

  void _onScanViewCreated(int id) {
    final channel = MethodChannel('bodhi/scan_view_$id');
    channel.setMethodCallHandler(_onScanMethodCall);
    _scanViewChannel = channel;
  }

  Future<dynamic> _onScanMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onReady':
        if (!mounted) break;
        setState(() {
          _cameraReady = true;
          _cameraError = false;
        });
        break;
      case 'torchAvailable':
        if (!mounted) break;
        setState(() => _hasTorch = (call.arguments as bool?) ?? true);
        break;
      case 'onDetected':
        await _handleDetected(call.arguments as String?);
        break;
      case 'onError':
        _onCameraFailed('相机启动失败，已切换为手动输入');
        break;
      default:
        break;
    }
    return null;
  }

  /// 处理识别结果（原生层回调的原始字符串）
  Future<void> _handleDetected(String? raw) async {
    if (_handlingResult || !mounted) return;
    if (raw == null || raw.isEmpty) return;

    // 分批导入时同一张二维码会继续留在取景框内，重复识别直接忽略
    if (_handledPayloads.contains(raw)) return;

    // 统一走批量解析：兼容 Google Authenticator 迁移二维码（多账号）
    final batch = OtpAuthParser.parseBatch(raw);
    if (!batch.ok) {
      // 不是令牌二维码：重置检测器继续扫，不打断用户
      try {
        await _scanViewChannel?.invokeMethod('reset');
      } catch (_) {}
      _showSnack(batch.error ?? '无法识别的二维码，请确认是动态令牌二维码');
      return;
    }

    _handlingResult = true;
    if (batch.hasMoreBatches) _handledPayloads.add(raw);
    await _deliverBatch(batch, keepScanning: batch.hasMoreBatches);
  }

  /// 导入成功后的统一收尾：震动反馈 → 回调调用方 →（分批时）留在本页
  Future<void> _deliverBatch(
    ParseBatchResult batch, {
    required bool keepScanning,
  }) async {
    // 震动反馈
    try {
      if (await Vibration.hasVibrator() ?? false) {
        await Vibration.vibrate(duration: 60);
      }
    } catch (_) {}

    if (!mounted) return;

    if (keepScanning) {
      // 后面还有二维码：立刻重新武装检测器，让用户可以直接扫下一张
      try {
        await _scanViewChannel?.invokeMethod('reset');
      } catch (_) {}
      _handlingResult = false;
    }

    // 导入落库由调用方完成；这里的异常绝不能冒泡到平台通道回调
    // （未捕获的异步异常会触发全局错误处理，扫码页是高风险入口）
    try {
      await widget.onBound(batch.items, keepScanning: keepScanning);
    } catch (_) {
      if (mounted) _showSnack('导入失败，请重试或改用「手动输入密钥」');
      return;
    }

    if (keepScanning && mounted) {
      _showSnack(
        '${batch.batchLabel ?? '本批'}已导入，请继续扫描下一页二维码',
        seconds: 4,
      );
    }
  }

  // ══════════════════════════════════════════════════════
  //  权限流程
  // ══════════════════════════════════════════════════════

  /// 进入页面时检查权限状态
  ///
  /// 关键：**只读状态，不主动申请**。
  /// 未申请过 → 停在 intro 阶段，等用户点「允许并开始扫码」
  Future<void> _checkPermissionOnEnter() async {
    try {
      final status = await Permission.camera.status;
      if (!mounted) return;

      if (status.isGranted) {
        // 已授权：直接进入扫码（原生视图随 AndroidView 挂载自动启动）
        setState(() => _stage = _ScanStage.scanning);
      } else if (status.isPermanentlyDenied || status.isRestricted) {
        setState(() => _stage = _ScanStage.denied);
      } else {
        // 未申请过（首次）→ 停在用途说明页
        setState(() => _stage = _ScanStage.intro);
      }
    } catch (_) {
      // 权限查询失败（原生异常）：降级到手动输入，不崩溃
      if (!mounted) return;
      setState(() {
        _cameraError = true;
        _stage = _ScanStage.cameraFailed;
      });
    }
  }

  /// 用户点击「允许并开始扫码」→ 正式申请系统权限
  Future<void> _requestCameraPermission() async {
    try {
      final status = await Permission.camera.request();
      if (!mounted) return;

      if (status.isGranted) {
        setState(() => _stage = _ScanStage.scanning);
      } else if (status.isPermanentlyDenied || status.isRestricted) {
        setState(() => _stage = _ScanStage.denied);
      } else {
        // 普通拒绝：给出引导，可再点一次
        setState(() => _stage = _ScanStage.denied);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _stage = _ScanStage.denied);
      _showSnack('无法申请相机权限，请到系统设置中手动开启');
    }
  }

  /// 相机失败统一处理
  void _onCameraFailed(String message) {
    if (!mounted) return;
    setState(() {
      _cameraReady = false;
      _cameraError = true;
      _stage = _ScanStage.cameraFailed;
    });
    _showSnack(message);
  }

  // ══════════════════════════════════════════════════════
  //  手动输入
  // ══════════════════════════════════════════════════════

  void _onManualChanged() {
    final valid = OtpAuthParser.looksValid(_manualController.text);
    if (valid != _manualValid || _manualError != null) {
      setState(() {
        _manualValid = valid;
        _manualError = null;
      });
    }
  }

  Future<void> _submitManual() async {
    final raw = _manualController.text.trim();
    if (raw.isEmpty) {
      setState(() => _manualError = OtpAuthParser.errEmpty);
      return;
    }

    final batch = OtpAuthParser.parseBatch(raw);
    if (!batch.ok) {
      setState(() => _manualError = batch.error);
      return;
    }

    if (!mounted) return;
    await _deliverBatch(batch, keepScanning: false);
  }

  // ══════════════════════════════════════════════════════
  //  构建
  // ══════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: BodhiColors.pageGradient),
      child: SafeArea(
        child: Column(
          children: [
            BodhiNavBar(
              title: '扫描绑定密钥',
              onBack: _handleBack,
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                child: _buildStageContent(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 返回上一页
  void _handleBack() {
    if (widget.onBack != null) {
      widget.onBack!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Widget _buildStageContent() {
    switch (_stage) {
      case _ScanStage.intro:
        return _buildIntro();
      case _ScanStage.scanning:
        return _buildScanner();
      case _ScanStage.cameraFailed:
        return _buildCameraFailed();
      case _ScanStage.denied:
        return _buildDenied();
      case _ScanStage.manualInput:
        return _buildManualInput();
    }
  }

  // ── 用途说明（申请权限前）────────────────────────────

  Widget _buildIntro() {
    return Column(
      children: [
        const SizedBox(height: 24),
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: BodhiColors.gold.withValues(alpha: 0.10),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.photo_camera_outlined,
            size: 34,
            color: BodhiColors.gold,
          ),
        ),
        const SizedBox(height: 20),
        Text('需要使用您的相机', style: BodhiTypography.pageTitle),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            '用于扫描二维码自动绑定动态令牌密钥。\n\n'
            '支持 Google Authenticator（谷歌令牌）「转移账号」导出的二维码，'
            '一次可批量导入全部账号；也支持标准 otpauth:// 单账号二维码。\n\n'
            '相机画面仅在您的设备上实时识别，'
            '不会拍摄、保存或上传任何图像内容。',
            style: BodhiTypography.body.copyWith(color: BodhiColors.inkGray),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 28),
        GoldButton(
          label: '允许并开始扫码',
          icon: Icons.qr_code_scanner,
          onPressed: _requestCameraPermission,
        ),
        const SizedBox(height: 12),
        OutlineGoldButton(
          label: '手动输入密钥',
          icon: Icons.keyboard_alt_outlined,
          onPressed: () => setState(() => _stage = _ScanStage.manualInput),
        ),
      ],
    );
  }

  // ── 取景框 ───────────────────────────────────────────

  Widget _buildScanner() {
    return Column(
      children: [
        const SizedBox(height: 8),
        Center(
          child: Container(
            width: 264,
            height: 264,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: BodhiColors.mossDeep,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Stack(
              children: [
                // 原生相机预览（CameraX PreviewView）
                Positioned.fill(child: _buildCameraPreview()),

                // 四角鎏金折角框
                ..._buildCorners(),

                // 扫描线（仅相机就绪时显示）
                if (_cameraReady) const _ScanLine(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _cameraReady ? '将二维码放入框内，即可自动识别' : '相机启动中…',
          style: BodhiTypography.caption,
        ),
        const SizedBox(height: 20),

        // 手电筒 / 相册
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _circleAction(
              icon: Icons.photo_library_outlined,
              label: '相册',
              onTap: _pickFromGallery,
            ),
            // 本机没有补光灯时不显示开关，避免“点了没反应”的错觉
            if (_hasTorch != false) ...[
              const SizedBox(width: 56),
              _circleAction(
                icon: Icons.flashlight_on_outlined,
                label: '手电筒',
                onTap: _toggleTorch,
              ),
            ],
          ],
        ),
        const SizedBox(height: 24),

        const TipBar(
          text: 'Google 令牌导出二维码字位很密：请让二维码尽量占满取景框'
              '（靠近一些），太远会扫不出来。浅色底/深色底都可识别。'
              '若始终扫不上，可截图后用「相册」导入截图，识别最稳。',
        ),
        const SizedBox(height: 16),

        _buildManualEntryCard(),
      ],
    );
  }

  /// 原生相机预览（CameraX + zxing 解码全部在原生层）
  Widget _buildCameraPreview() {
    return AndroidView(
      viewType: 'bodhi/scan_view',
      onPlatformViewCreated: _onScanViewCreated,
    );
  }

  List<Widget> _buildCorners() {
    const len = 28.0;
    const thick = 3.0;
    final color = BodhiColors.goldLight;

    Widget corner({required bool top, required bool left}) {
      return Positioned(
        top: top ? 12 : null,
        bottom: top ? null : 12,
        left: left ? 12 : null,
        right: left ? null : 12,
        child: SizedBox(
          width: len,
          height: len,
          child: CustomPaint(
            painter: _CornerPainter(
              color: color,
              thickness: thick,
              top: top,
              left: left,
            ),
          ),
        ),
      );
    }

    return [
      corner(top: true, left: true),
      corner(top: true, left: false),
      corner(top: false, left: true),
      corner(top: false, left: false),
    ];
  }

  Widget _circleAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: BodhiColors.cardWhite,
              shape: BoxShape.circle,
              border: Border.all(
                color: BodhiColors.gold.withValues(alpha: 0.35),
              ),
            ),
            child: Icon(icon, size: 22, color: BodhiColors.gold),
          ),
          const SizedBox(height: 6),
          Text(label, style: BodhiTypography.caption),
        ],
      ),
    );
  }

  Widget _buildManualEntryCard() {
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      children: [
        Row(
          children: [
            const Icon(
              Icons.keyboard_alt_outlined,
              size: 18,
              color: BodhiColors.gold,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('无法扫码？手动输入', style: BodhiTypography.rowLabel),
                  const SizedBox(height: 2),
                  Text(
                    '支持 Google 令牌二维码、otpauth 链接或 Base32 密钥',
                    style: BodhiTypography.rowHint,
                  ),                ],
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _stage = _ScanStage.manualInput),
              child: Text(
                '去输入',
                style: BodhiTypography.rowValue.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── 相机初始化失败 ───────────────────────────────────

  Widget _buildCameraFailed() {
    return Column(
      children: [
        const SizedBox(height: 24),
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: BodhiColors.cinnabar.withValues(alpha: 0.08),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.videocam_off_outlined,
            size: 34,
            color: BodhiColors.cinnabar,
          ),
        ),
        const SizedBox(height: 20),
        Text('相机启动失败', style: BodhiTypography.pageTitle),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            '可能是相机被其他应用占用，或设备不支持。\n\n'
            '您可以直接使用手动输入密钥的方式添加令牌。',
            style: BodhiTypography.body.copyWith(color: BodhiColors.inkGray),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 28),
        GoldButton(
          label: '重试',
          icon: Icons.refresh,
          onPressed: () => setState(() => _stage = _ScanStage.scanning),
        ),
        const SizedBox(height: 12),
        OutlineGoldButton(
          label: '手动输入密钥',
          icon: Icons.keyboard_alt_outlined,
          onPressed: () => setState(() => _stage = _ScanStage.manualInput),
        ),
      ],
    );
  }

  // ── 权限被拒 ─────────────────────────────────────────

  Widget _buildDenied() {
    return Column(
      children: [
        const SizedBox(height: 24),
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            color: BodhiColors.cinnabar.withValues(alpha: 0.08),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.no_photography_outlined,
            size: 34,
            color: BodhiColors.cinnabar,
          ),
        ),
        const SizedBox(height: 20),
        Text('无法使用摄像头', style: BodhiTypography.pageTitle),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            '您已拒绝相机权限，暂时无法扫码绑定。\n\n'
            '您可以前往系统设置为「菩提护令」开启相机权限，'
            '或直接使用手动输入密钥的方式添加令牌。',
            style: BodhiTypography.body.copyWith(color: BodhiColors.inkGray),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 28),
        GoldButton(
          label: '前往系统设置',
          icon: Icons.settings_outlined,
          onPressed: _openSystemSettings,
        ),
        const SizedBox(height: 12),
        OutlineGoldButton(
          label: '再试一次',
          icon: Icons.refresh,
          onPressed: _requestCameraPermission,
        ),
        const SizedBox(height: 10),
        OutlineGoldButton(
          label: '手动输入密钥',
          icon: Icons.keyboard_alt_outlined,
          onPressed: () => setState(() => _stage = _ScanStage.manualInput),
        ),
      ],
    );
  }

  Future<void> _openSystemSettings() async {
    try {
      await openAppSettings();
    } catch (_) {
      _showSnack('无法打开系统设置，请手动前往「设置 → 应用 → 菩提护令」');
    }
  }

  // ── 手动输入 ─────────────────────────────────────────

  Widget _buildManualInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          '手动输入密钥',
          style: BodhiTypography.pageTitle,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          '粘贴 otpauth:// 链接、Google 令牌迁移链接，或直接输入 Base32 密钥',
          style: BodhiTypography.caption,
          textAlign: TextAlign.center,
        ),        const SizedBox(height: 20),

        TextField(
          controller: _manualController,
          maxLines: 3,
          minLines: 2,
          style: BodhiTypography.secretCode,
          decoration: InputDecoration(
            hintText: 'otpauth://totp/...\n或 JBSW Y3DP EHPK 3PXP',
            hintStyle: BodhiTypography.caption.copyWith(
              color: BodhiColors.inkFaint,
            ),
            filled: true,
            fillColor: BodhiColors.fieldBg,
            contentPadding: const EdgeInsets.all(14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(
                color: _manualValid
                    ? BodhiColors.moss.withValues(alpha: 0.5)
                    : BodhiColors.divider,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: BodhiColors.gold, width: 1.4),
            ),
            errorText: _manualError,
          ),
          onSubmitted: (_) => _submitManual(),
        ),

        const SizedBox(height: 8),
        if (_manualValid)
          Row(
            children: [
              const Icon(
                Icons.check_circle_outline,
                size: 14,
                color: BodhiColors.moss,
              ),
              const SizedBox(width: 6),
              Text(
                '密钥格式正确',
                style: BodhiTypography.caption.copyWith(
                  color: BodhiColors.moss,
                ),
              ),
            ],
          ),

        const SizedBox(height: 20),
        GoldButton(label: '确认绑定', onPressed: _submitManual),
        const SizedBox(height: 12),

        // 返回扫码（若相机曾失败则直接返回上一页）
        OutlineGoldButton(
          label: _cameraError ? '返回' : '返回扫码',
          onPressed: () {
            if (_cameraError) {
              if (widget.onBack != null) {
                widget.onBack!();
              } else {
                Navigator.of(context).maybePop();
              }
            } else {
              setState(() => _stage = _ScanStage.scanning);
            }
          },
        ),

        const SizedBox(height: 20),
        const TipBar(
          text: '密钥是您账号安全的核心凭据，请勿通过聊天工具、邮件等不安全渠道传输。',
        ),
      ],
    );
  }

  // ── 小工具 ───────────────────────────────────────────

  /// 从相册选择二维码图片，交由原生 zxing 解码
  ///
  /// 关键：安卓系统选图器（Photo Picker / ACTION_GET_CONTENT）本身
  /// **不需要任何运行时权限**。此前先申请 READ_MEDIA_IMAGES 的做法在
  /// 权限被「不再询问」后会静默失败，导致相册导入永远打不开。
  /// 因此这里改为：直接选图 → 选图器报错才降级申请权限重试 →
  /// 仍不行引导用户去系统设置手动开启。
  /// ⚠️ 全流程 try-catch：系统相册被拒 / 图片读取失败都不能崩溃
  Future<void> _pickFromGallery() async {
    if (_picking) return;
    _picking = true;

    try {
      // 1. 直接选取图片（无需任何权限；用户取消返回 null）
      final picker = ImagePicker();
      XFile? file;
      try {
        file = await picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 2400,
          maxHeight: 2400,
        );
      } catch (_) {
        // 个别 ROM 选图器异常：降级申请相册权限后重试一次
        final granted = await PermissionService.instance.requestGallery();
        if (!mounted) return;
        if (!granted) {
          _picking = false;
          _guideToSettings('相册权限被拒绝，请到系统设置中手动开启');
          return;
        }
        file = await picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 2400,
          maxHeight: 2400,
        );
      }

      if (file == null) {
        // 用户取消选择，静默返回
        _picking = false;
        return;
      }

      // 2. 原生 zxing 解码（与相机扫码同一解码核心，无 Google 服务依赖）
      final raw = await MethodChannel('bodhi/scan')
          .invokeMethod<String>('decodeFromFile', {'path': file.path});

      if (raw == null || raw.isEmpty) {
        _picking = false;
        _showSnack('图片中未识别到二维码，请选择更清晰的截图');
        return;
      }

      // 3. 复用统一的批量解析流程（兼容 Google 迁移二维码多账号）
      final batch = OtpAuthParser.parseBatch(raw);
      if (!batch.ok) {
        _picking = false;
        _showSnack(batch.error ?? '无法识别的二维码，请确认是令牌二维码');
        return;
      }

      // 4. 震动反馈后绑定
      _picking = false;
      if (!mounted) return;
      await _deliverBatch(batch, keepScanning: false);
    } catch (_) {
      // ⚠️ 任何异常都不崩溃
      _picking = false;
      _showSnack('相册读取失败，可改用「手动输入密钥」');
    }
  }

  /// 权限被拒后的引导：提示 + 提供「去系统设置」按钮
  void _guideToSettings(String message) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: BodhiColors.cardWhite,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: Text('需要相册权限', style: BodhiTypography.pageTitle),
          content: Text(
            '$message。\n\n'
            '路径：系统设置 → 应用 → 菩提护令 → 权限 → '
            '允许访问照片和视频。',
            style: BodhiTypography.body.copyWith(
              color: BodhiColors.inkGray,
              height: 1.7,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(
                '取消',
                style: BodhiTypography.rowLabel.copyWith(
                  color: BodhiColors.inkGray,
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                PermissionService.instance.openSettings();
              },
              child: Text(
                '去系统设置',
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

  Future<void> _toggleTorch() async {
    if (!_cameraReady) {
      _showSnack('相机未就绪，无法控制补光灯');
      return;
    }
    try {
      final on = await _scanViewChannel?.invokeMethod<bool>('toggleTorch');
      if (!mounted) return;
      if (on == false && _hasTorch == false) {
        _showSnack('本机没有可用的补光灯');
      }
    } catch (_) {
      // 部分设备不支持补光灯
      if (mounted) _showSnack('本机没有可用的补光灯');
    }
  }

  void _showSnack(String message, {int seconds = 2}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // 扫码会连续触发识别，新提示直接顶掉旧提示，避免排队堆积
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: BodhiTypography.caption.copyWith(
            color: BodhiColors.paperLight,
          ),
        ),
        backgroundColor: BodhiColors.inkBrown,
        duration: Duration(seconds: seconds),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// 扫描线动画
class _ScanLine extends StatefulWidget {
  const _ScanLine();

  @override
  State<_ScanLine> createState() => _ScanLineState();
}

class _ScanLineState extends State<_ScanLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Positioned(
          top: 20 + (224 - 20) * _controller.value,
          left: 16,
          right: 16,
          child: Container(
            height: 2,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  Colors.transparent,
                  BodhiColors.goldGlow,
                  Colors.transparent,
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: BodhiColors.goldGlow.withValues(alpha: 0.55),
                  blurRadius: 8,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 取景框折角
class _CornerPainter extends CustomPainter {
  final Color color;
  final double thickness;
  final bool top;
  final bool left;

  _CornerPainter({
    required this.color,
    required this.thickness,
    required this.top,
    required this.left,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;

    final hStart = Offset(left ? 0 : size.width, top ? 0 : size.height);
    final hEnd = Offset(left ? size.width : 0, top ? 0 : size.height);
    final vEnd = Offset(left ? 0 : size.width, top ? size.height : 0);

    canvas.drawLine(hStart, hEnd, paint);
    canvas.drawLine(hStart, vEnd, paint);
  }

  @override
  bool shouldRepaint(covariant _CornerPainter old) =>
      old.color != color || old.top != top || old.left != left;
}
