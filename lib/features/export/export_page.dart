import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/security/clipboard_guard.dart';
import '../../data/models/token.dart';
import '../../data/repository/token_repository.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/common.dart';

/// S6 导出密钥 · 二维码与文本
///
/// 两种导出形式：
///   1. 二维码 —— 供其他验证器 App 扫码导入
///   2. Base32 文本 —— 供手动录入
///
/// 安全提示：导出内容等价于账号凭据，必须妥善保管。
class ExportPage extends StatefulWidget {
  final Token token;
  final VoidCallback onBack;

  const ExportPage({
    super.key,
    required this.token,
    required this.onBack,
  });

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  final GlobalKey _qrBoundaryKey = GlobalKey();

  String? _otpAuthUri;
  String? _plainSecret;
  bool _obscured = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSecret();
  }

  @override
  void dispose() {
    // 离开页面时不残留敏感内容
    _plainSecret = null;
    super.dispose();
  }

  void _loadSecret() {
    final repo = TokenRepository.instance;
    _plainSecret = repo.plainSecret(widget.token);
    _otpAuthUri = repo.exportUri(widget.token);
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: BodhiColors.pageGradient),
      child: SafeArea(
        child: Column(
          children: [
            BodhiNavBar(title: '导出密钥', onBack: widget.onBack),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                child: _plainSecret == null
                    ? _buildError()
                    : Column(
                        children: [
                          _buildTokenCard(),
                          const SizedBox(height: 12),
                          _buildQrCard(),
                          const SizedBox(height: 12),
                          _buildTextCard(),
                          const SizedBox(height: 14),
                          _buildButtons(),
                          const SizedBox(height: 14),
                          const TipBar(
                            icon: Icons.warning_amber_outlined,
                            text: '导出的密钥等同于账号凭据，泄露将导致任何人均可生成您的动态验证码。'
                                '请勿截图分享或通过网络传输，建议导出后立即保存至加密备份。',
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

  Widget _buildError() {
    return Column(
      children: [
        const SizedBox(height: 60),
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: BodhiColors.cinnabar.withValues(alpha: 0.08),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.lock_outline,
            size: 32,
            color: BodhiColors.cinnabar,
          ),
        ),
        const SizedBox(height: 20),
        Text('无法读取密钥', style: BodhiTypography.pageTitle),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '密钥解密失败，可能是系统安全区数据已变更。\n'
            '该令牌无法导出，建议删除后重新绑定。',
            style: BodhiTypography.caption,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  /// 令牌信息卡
  Widget _buildTokenCard() {
    return SectionCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      children: [
        Row(
          children: [
            TokenDot(colorIndex: widget.token.colorTag, size: 10),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.token.subtitle.isEmpty
                        ? widget.token.title
                        : '${widget.token.title} · ${widget.token.subtitle}',
                    style: BodhiTypography.tokenIssuer.copyWith(fontSize: 15),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${widget.token.algorithm} · ${widget.token.digits} 位 · '
                    '${widget.token.period} 秒',
                    style: BodhiTypography.caption,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 二维码卡片
  Widget _buildQrCard() {
    final uri = _otpAuthUri;
    if (uri == null) return const SizedBox.shrink();

    return SectionCard(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      children: [
        Center(
          child: RepaintBoundary(
            key: _qrBoundaryKey,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.white,
              child: QrImageView(
                data: uri,
                version: QrVersions.auto,
                size: 180,
                gapless: true,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: BodhiColors.inkBrown,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: BodhiColors.inkBrown,
                ),
                // 二维码中心嵌入金莲
                embeddedImage: null,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '使用其他验证器 App 扫码即可导入此密钥',
          style: BodhiTypography.caption,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// 文本卡片
  Widget _buildTextCard() {
    final secret = _plainSecret;
    if (secret == null) return const SizedBox.shrink();

    return SectionCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      children: [
        Row(
          children: [
            Text('密钥文本（Base32）', style: BodhiTypography.fieldLabel),
            const Spacer(),
            GestureDetector(
              onTap: () => setState(() => _obscured = !_obscured),
              child: Row(
                children: [
                  Icon(
                    _obscured
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 14,
                    color: BodhiColors.inkFaint,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _obscured ? '显示' : '隐藏',
                    style: BodhiTypography.caption.copyWith(fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: BodhiColors.fieldBg,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _obscured ? _maskSecret(secret) : _groupSecret(secret),
                  style: BodhiTypography.secretCode,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _copySecret(secret),
                child: const Icon(
                  Icons.copy_rounded,
                  size: 16,
                  color: BodhiColors.gold,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 隐藏时用圆点替换
  String _maskSecret(String secret) {
    final grouped = _groupSecret(secret);
    return grouped.replaceAll(RegExp(r'[A-Z2-7]'), '•');
  }

  /// 每 4 位加空格，便于核对
  String _groupSecret(String secret) {
    final buffer = StringBuffer();
    for (var i = 0; i < secret.length; i++) {
      if (i > 0 && i % 4 == 0) buffer.write(' ');
      buffer.write(secret[i]);
    }
    return buffer.toString();
  }

  Future<void> _copySecret(String secret) async {
    await ClipboardGuard.copySensitive(secret, autoClearSeconds: 30);
    if (!mounted) return;
    _snack('密钥已复制（30 秒后自动清除剪贴板）');
  }

  /// 双按钮
  Widget _buildButtons() {
    return Row(
      children: [
        Expanded(
          child: GoldButton(
            label: '复制文本',
            icon: Icons.copy_rounded,
            onPressed: () {
              final secret = _plainSecret;
              if (secret != null) _copySecret(secret);
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlineGoldButton(
            label: _saving ? '保存中…' : '保存为图片',
            icon: Icons.download_outlined,
            onPressed: _saving ? null : _saveQrImage,
          ),
        ),
      ],
    );
  }

  /// 将二维码保存为图片到相册
  Future<void> _saveQrImage() async {
    setState(() => _saving = true);

    try {
      // 1. 申请相册写入权限
      if (Platform.isIOS) {
        final status = await Permission.photos.request();
        if (!status.isGranted && !status.isLimited) {
          if (mounted) {
            setState(() => _saving = false);
            _snack('未获得相册权限，无法保存图片。请在系统设置中开启。');
          }
          return;
        }
      } else {
        final status = await Permission.storage.request();
        // Android 10+ 使用 MediaStore 写入通常无需显式授权，失败时继续尝试
        if (status.isPermanentlyDenied) {
          if (mounted) {
            setState(() => _saving = false);
            _snack('未获得存储权限，无法保存图片。请在系统设置中开启。');
          }
          return;
        }
      }

      // 2. 渲染二维码为图片
      final boundary = _qrBoundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        if (mounted) {
          setState(() => _saving = false);
          _snack('生成图片失败，请重试');
        }
        return;
      }

      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final ByteData? byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);

      if (byteData == null) {
        if (mounted) {
          setState(() => _saving = false);
          _snack('生成图片失败，请重试');
        }
        return;
      }

      // 3. 保存到相册
      final bytes = byteData.buffer.asUint8List();
      final result = await ImageGallerySaver.saveImage(
        bytes,
        name: 'bodhi_token_${DateTime.now().millisecondsSinceEpoch}',
      );

      if (!mounted) return;
      setState(() => _saving = false);

      final ok = result is Map && result['isSuccess'] == true;
      _snack(ok ? '二维码已保存到相册' : '保存失败，请检查相册权限');
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('保存失败，请稍后重试');
    }
  }

  void _snack(String message) {
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
}

/// 供 S6 使用的无状态包装（从列表页带 Token 跳入）
class ExportRoute extends StatelessWidget {
  final Token token;
  final VoidCallback onBack;

  const ExportRoute({
    super.key,
    required this.token,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return ExportPage(token: token, onBack: onBack);
  }
}
