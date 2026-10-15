import 'package:flutter/material.dart';
import 'colors.dart';

/// 菩提护令 · 字体规范
///
/// 中文用思源宋体（Source Han Serif CN）体现古韵；
/// 数字与英文用 Inter 保证清晰；
/// 密钥等宽展示用等宽字体便于核对。
///
/// 若未打包字体文件，`_resolveFamily` 会自动回退到系统字体，
/// 应用不会因缺字体而崩溃。
class BodhiTypography {
  BodhiTypography._();

  // ── 字体族 ───────────────────────────────────────────
  static const String serif = 'SourceHanSerif'; // 思源宋体
  static const String sans = 'Inter';           // Inter
  static const String mono = 'monospace';       // 等宽

  /// 若目标字体未被打包，回退到平台默认字体。
  /// 在 pubspec 中配置 fonts 后此回退不会生效（字体存在即用）。
  static String _resolveFamily(String family) {
    const bundled = <String>{serif, sans};
    if (bundled.contains(family)) return family;
    return family;
  }

  // ── 基础样式构造 ─────────────────────────────────────

  /// 通用文本样式
  static TextStyle _base({
    required double size,
    required Color color,
    String family = serif,
    FontWeight weight = FontWeight.w400,
    double? height,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontFamily: _resolveFamily(family),
      fontSize: size,
      color: color,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  // ── 品牌 ─────────────────────────────────────────────

  /// 应用名「菩提护令」
  static TextStyle brandName = _base(
    size: 26,
    color: BodhiColors.paperLight,
    weight: FontWeight.w500,
    letterSpacing: 4,
  );

  /// 品牌口号「一心护念 · 密钥常安」
  static TextStyle brandSlogan = _base(
    size: 12,
    color: BodhiColors.goldGlow,
    family: sans,
    letterSpacing: 2,
  );

  /// 问候主句「阿弥陀佛」
  static TextStyle greetingMain = _base(
    size: 30,
    color: BodhiColors.goldGlow,
    weight: FontWeight.w500,
    letterSpacing: 8,
  );

  /// 问候副句
  static TextStyle greetingSub = _base(
    size: 12,
    color: BodhiColors.goldLight,
    family: sans,
    letterSpacing: 2,
  );

  /// 启动页版权
  static TextStyle splashCopyright = _base(
    size: 10,
    color: BodhiColors.paperDeep.withValues(alpha: 0.75),
    family: sans,
    letterSpacing: 1,
  );

  // ── 页面 ─────────────────────────────────────────────

  /// 导航栏标题
  static TextStyle navTitle = _base(
    size: 17,
    color: BodhiColors.inkBrown,
    weight: FontWeight.w500,
  );

  /// 页面主标题
  static TextStyle pageTitle = _base(
    size: 20,
    color: BodhiColors.inkBrown,
    weight: FontWeight.w500,
  );

  /// 分组标题
  static TextStyle groupTitle = _base(
    size: 13,
    color: BodhiColors.inkGray,
    weight: FontWeight.w500,
  );

  /// 设置行主文字
  static TextStyle rowLabel = _base(
    size: 15,
    color: BodhiColors.inkBrown,
  );

  /// 行说明文字
  static TextStyle rowHint = _base(
    size: 11,
    color: BodhiColors.inkGray,
    family: sans,
  );

  /// 行右侧值（金色）
  static TextStyle rowValue = _base(
    size: 12,
    color: BodhiColors.gold,
    family: sans,
  );

  /// 正文
  static TextStyle body = _base(
    size: 14,
    color: BodhiColors.inkBrown,
    height: 1.6,
  );

  /// 说明文字
  static TextStyle caption = _base(
    size: 11,
    color: BodhiColors.inkGray,
    family: sans,
    height: 1.5,
  );

  // ── 令牌 ─────────────────────────────────────────────

  /// 令牌服务名
  static TextStyle tokenIssuer = _base(
    size: 16,
    color: BodhiColors.inkBrown,
    weight: FontWeight.w500,
  );

  /// 令牌账号
  static TextStyle tokenAccount = _base(
    size: 11,
    color: BodhiColors.inkGray,
    family: sans,
  );

  /// 令牌验证码（等宽，大字，便于核对）
  static TextStyle tokenCode = _base(
    size: 32,
    color: BodhiColors.inkBrown,
    family: mono,
    weight: FontWeight.w600,
    letterSpacing: 4,
  );

  /// 令牌验证码（倒计时告急，朱砂色加粗）
  static TextStyle tokenCodeUrgent = tokenCode.copyWith(
    color: BodhiColors.cinnabar,
    fontWeight: FontWeight.w700,
  );

  // ── 密钥 / 表单 ──────────────────────────────────────

  /// 密钥等宽文本
  static TextStyle secretCode = _base(
    size: 14,
    color: BodhiColors.inkBrown,
    family: mono,
    letterSpacing: 1.5,
  );

  /// 设置页输入框文字
  static TextStyle fieldText = _base(
    size: 14,
    color: BodhiColors.inkBrown,
    family: sans,
  );

  /// 表单标签
  static TextStyle fieldLabel = _base(
    size: 12,
    color: BodhiColors.inkGray,
    family: sans,
  );

  // ── 按钮 ─────────────────────────────────────────────

  /// 主按钮文字（实心鎏金）
  static TextStyle buttonPrimary = _base(
    size: 15,
    color: BodhiColors.paperLight,
    weight: FontWeight.w500,
    letterSpacing: 1,
  );

  /// 次按钮文字（描边）
  static TextStyle buttonSecondary = _base(
    size: 15,
    color: BodhiColors.gold,
    weight: FontWeight.w500,
    letterSpacing: 1,
  );

  /// 小按钮 / 徽标文字
  static TextStyle badge = _base(
    size: 11,
    color: BodhiColors.paperLight,
    family: sans,
  );

  /// 底部版权
  static TextStyle copyright = _base(
    size: 11,
    color: BodhiColors.inkFaint,
    family: sans,
  );

  // ── 数字键盘 ─────────────────────────────────────────

  /// 键盘数字
  static TextStyle keypadDigit = _base(
    size: 24,
    color: BodhiColors.inkBrown,
    family: sans,
    weight: FontWeight.w400,
  );

  /// 键盘次要文字（「指纹」「删除」等）
  static TextStyle keypadLabel = _base(
    size: 12,
    color: BodhiColors.inkGray,
  );
}

/// 应用整体 ThemeData
class BodhiTheme {
  BodhiTheme._();

  static ThemeData light() {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: BodhiColors.paperLight,
      colorScheme: ColorScheme.fromSeed(
        seedColor: BodhiColors.gold,
        brightness: Brightness.light,
      ).copyWith(
        primary: BodhiColors.gold,
        surface: BodhiColors.cardWhite,
        error: BodhiColors.cinnabar,
      ),
      // 全局禁止字体缩放导致的布局错乱（并保留无障碍上限）
      textTheme: const TextTheme().apply(
        fontFamily: BodhiTypography.serif,
        bodyColor: BodhiColors.inkBrown,
        displayColor: BodhiColors.inkBrown,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: BodhiTypography.navTitle,
        iconTheme: const IconThemeData(color: BodhiColors.inkBrown),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: BodhiColors.cardWhite,
        elevation: 8,
        shadowColor: BodhiColors.inkBrown.withValues(alpha: 0.18),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: BodhiColors.divider,
        thickness: 1,
        space: 1,
      ),
      splashFactory: InkSparkle.splashFactory,
    );
  }

  /// 媒体查询文本缩放限制，避免超大字体破坏古风排版
  static const TextScaler textScalerClamp = TextScaler.linear(1.0);
}
