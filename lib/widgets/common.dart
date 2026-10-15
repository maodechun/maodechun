import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';

/// 鎏金主按钮（实心）
class GoldButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expanded;
  final double height;
  final bool loading;

  const GoldButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expanded = true,
    this.height = 46,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;

    final content = loading
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(BodhiColors.paperLight),
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: BodhiColors.paperLight),
                const SizedBox(width: 6),
              ],
              Text(label, style: BodhiTypography.buttonPrimary),
            ],
          );

    return SizedBox(
      width: expanded ? double.infinity : null,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: enabled ? BodhiColors.goldGradient : null,
          color: enabled ? null : BodhiColors.switchOff,
          borderRadius: BorderRadius.circular(height / 2),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: BodhiColors.gold.withValues(alpha: 0.28),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(height / 2),
            child: Center(child: content),
          ),
        ),
      ),
    );
  }
}

/// 描边次按钮
class OutlineGoldButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expanded;
  final double height;

  const OutlineGoldButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.expanded = true,
    this.height = 46,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;

    return SizedBox(
      width: expanded ? double.infinity : null,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(height / 2),
          border: Border.all(
            color: enabled
                ? BodhiColors.gold
                : BodhiColors.switchOff,
            width: 1.2,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: enabled ? onPressed : null,
            borderRadius: BorderRadius.circular(height / 2),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(
                      icon,
                      size: 18,
                      color: enabled
                          ? BodhiColors.gold
                          : BodhiColors.inkFaint,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: BodhiTypography.buttonSecondary.copyWith(
                      color: enabled
                          ? BodhiColors.gold
                          : BodhiColors.inkFaint,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 令牌色点
class TokenDot extends StatelessWidget {
  final int colorIndex;
  final double size;

  const TokenDot({
    super.key,
    required this.colorIndex,
    this.size = 10,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        BodhiColors.tokenTags[colorIndex % BodhiColors.tokenTags.length];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// 分组卡片容器（白色圆角，含可选标题）
class SectionCard extends StatelessWidget {
  final String? title;
  final String? trailingLabel;
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  const SectionCard({
    super.key,
    this.title,
    this.trailingLabel,
    required this.children,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(title!, style: BodhiTypography.groupTitle),
                  ),
                  if (trailingLabel != null)
                    Text(trailingLabel!, style: BodhiTypography.rowHint),
                ],
              ),
            ),
          Padding(
            padding: padding ?? const EdgeInsets.only(bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置行（图标 + 标题 + 可选说明 + 右侧控件）
class SettingRow extends StatelessWidget {
  final Widget? leading;
  final String label;
  final String? hint;
  final Widget? trailing;
  final VoidCallback? onTap;
  final double height;
  final bool showDivider;

  const SettingRow({
    super.key,
    this.leading,
    required this.label,
    this.hint,
    this.trailing,
    this.onTap,
    this.height = 44,
    this.showDivider = false,
  });

  @override
  Widget build(BuildContext context) {
    final row = SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            if (leading != null) ...[
              SizedBox(width: 20, height: 20, child: leading),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: BodhiTypography.rowLabel),
                  if (hint != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      hint!,
                      style: BodhiTypography.rowHint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              trailing!,
            ],
          ],
        ),
      ),
    );

    final content = showDivider
        ? Column(
            children: [
              const Divider(height: 1, indent: 16, endIndent: 16),
              row,
            ],
          )
        : row;

    if (onTap == null) return content;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: content,
      ),
    );
  }
}

/// 金线风格开关
class GoldSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const GoldSwitch({
    super.key,
    required this.value,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 44,
        height: 26,
        decoration: BoxDecoration(
          color: value ? BodhiColors.gold : BodhiColors.switchOff,
          borderRadius: BorderRadius.circular(13),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 22,
            height: 22,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(11),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 安全提示条
class TipBar extends StatelessWidget {
  final String text;
  final IconData icon;

  const TipBar({
    super.key,
    required this.text,
    this.icon = Icons.info_outline,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: BodhiColors.tipBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: BodhiColors.tipText),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: BodhiTypography.caption.copyWith(
                color: BodhiColors.tipText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 页面导航栏（与设计稿统一）
class BodhiNavBar extends StatelessWidget {
  final String title;
  final VoidCallback? onBack;
  final Widget? trailing;

  const BodhiNavBar({
    super.key,
    required this.title,
    this.onBack,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: onBack == null
                  ? null
                  : GestureDetector(
                      onTap: onBack,
                      behavior: HitTestBehavior.opaque,
                      child: const Icon(
                        Icons.arrow_back_ios_new,
                        size: 18,
                        color: BodhiColors.inkBrown,
                      ),
                    ),
            ),
            Expanded(
              child: Center(
                child: Text(title, style: BodhiTypography.navTitle),
              ),
            ),
            SizedBox(
              width: 24,
              height: 24,
              child: trailing == null
                  ? null
                  : Align(alignment: Alignment.centerRight, child: trailing),
            ),
          ],
        ),
      ),
    );
  }
}
