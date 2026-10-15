import 'package:flutter/material.dart';

/// 菩提护令 · 色板
///
/// 设计语言：古色古香 · 宣纸米黄底色 + 鎏金强调
/// 全部颜色来源于设计稿《菩提护令 App 设计稿》的变量集「菩提护令·色板」
class BodhiColors {
  BodhiColors._();

  // ── 底色 · 宣纸 ──────────────────────────────────────
  /// 宣纸底（页面背景渐变起始）
  static const Color paperLight = Color(0xFFF3EAD5);

  /// 宣纸深（页面背景渐变结束）
  static const Color paperDeep = Color(0xFFE6D7B4);

  /// 卡片白（分组卡背景，暖白微调，避免纯白的生硬）
  static const Color cardWhite = Color(0xFFFFFCF3);

  // ── 强调 · 鎏金 ──────────────────────────────────────
  /// 鎏金（主强调色、图标、开关开启态）——加深后更沉稳贵气
  static const Color gold = Color(0xFF9A6F18);

  /// 鎏金浅（渐变亮部）
  static const Color goldLight = Color(0xFFC6992F);

  /// 鎏金高光（光晕中心）
  static const Color goldGlow = Color(0xFFD8A946);

  // ── 语义色 ───────────────────────────────────────────
  /// 朱砂（警示、倒计时告急、新版本徽标）
  static const Color cinnabar = Color(0xFF8C3B33);

  /// 墨绿（成功态、夜间点缀）
  static const Color moss = Color(0xFF42603A);

  /// 墨绿深（夜间背景）
  static const Color mossDeep = Color(0xFF0E241C);

  // ── 文字 ─────────────────────────────────────────────
  /// 檀棕（主文字）——加深提升对比度与分量感
  static const Color inkBrown = Color(0xFF2E2415);

  /// 灰棕（次级文字、说明文字）
  static const Color inkGray = Color(0xFF79684D);

  /// 版权灰（最弱层级）
  static const Color inkFaint = Color(0xFF97825F);

  // ── 辅助 ─────────────────────────────────────────────
  /// 输入框底色
  static const Color fieldBg = Color(0xFFF5EAD0);

  /// 提示条底色
  static const Color tipBg = Color(0xFFEEDFB6);

  /// 提示条文字
  static const Color tipText = Color(0xFF6E501F);

  /// 分割线
  static const Color divider = Color(0xFFE2D3B0);

  /// 开关关闭态轨道
  static const Color switchOff = Color(0xFFCDBD97);

  // ── 令牌色标（用户可选的卡片标记色）─────────────────
  static const List<Color> tokenTags = [
    Color(0xFFB8892E), // 鎏金
    Color(0xFF8C3B33), // 朱砂
    Color(0xFF4A6741), // 墨绿
    Color(0xFF4A5D7E), // 黛蓝
    Color(0xFF7B5E86), // 紫檀
    Color(0xFF9A6B3F), // 赭石
  ];

  // ── 渐变 ─────────────────────────────────────────────

  /// 页面背景渐变（宣纸米黄 → 淡旧），自上而下
  static const LinearGradient pageGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [paperLight, paperDeep],
  );

  /// 鎏金渐变（按钮、徽记）
  static const LinearGradient goldGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [goldLight, gold],
  );

  /// 夜间渐变（晚课态、启动页）
  static const LinearGradient nightGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF16283A), Color(0xFF0B1620)],
  );

  /// 启动页文字遮罩（底部向上渐隐，保证文字可读）
  static const LinearGradient splashScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.45, 1.0],
    colors: [Color(0x00000000), Color(0x66000000), Color(0xCC000000)],
  );
}
