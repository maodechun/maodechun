import 'package:flutter/material.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/common.dart';

/// 隐私政策页
///
/// 合规要求（应用商店审核必查）：
///   1. 首次启动必须展示，未同意不得进入应用
///   2. 内容须包含信息收集范围、权限用途、数据存储与共享说明
///   3. 必须可公网访问（同一份内容需上线为 https 页面）
class PrivacyPolicyPage extends StatelessWidget {
  /// 是否处于「首次启动同意」模式
  final bool consentMode;

  /// 同意回调（仅在 consentMode 下使用）
  final VoidCallback? onAgree;

  /// 不同意并退出
  final VoidCallback? onDecline;

  const PrivacyPolicyPage({
    super.key,
    this.consentMode = false,
    this.onAgree,
    this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 同意模式下禁止返回手势绕过
      canPop: !consentMode,
      child: DecoratedBox(
        decoration: const BoxDecoration(gradient: BodhiColors.pageGradient),
        child: SafeArea(
          child: Column(
            children: [
              BodhiNavBar(
                title: '隐私政策',
                onBack: consentMode
                    ? null
                    : () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildHeader(),
                      const SizedBox(height: 20),
                      ..._buildSections(),
                      const SizedBox(height: 20),
                      _buildFooter(),
                      const SizedBox(height: 16),
                      if (consentMode) _buildConsentButtons(context),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: BodhiColors.gold.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.shield_outlined,
              size: 30,
              color: BodhiColors.gold,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            '菩提护令 隐私政策',
            style: BodhiTypography.pageTitle,
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            '生效日期：2026 年 10 月 14 日 · 版本 v1.1',
            style: BodhiTypography.caption.copyWith(fontSize: 11),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildSections() {
    return [
      _section(
        '一、我们收集哪些信息',
        '本应用不收集、不存储、不上传您的任何个人信息。具体而言：\n'
            '1. 本应用没有账号体系，无需注册、无需登录，我们无法识别您的身份。\n'
            '2. 您录入或扫码获得的动态令牌密钥，仅经过加密后保存在您的设备本机，'
            '我们无法访问、无法获取、无法解密。\n'
            '3. 本应用不采集设备唯一标识用于用户画像或广告投放。\n'
            '4. 本应用不采集您的位置信息用于任何商业用途。',
      ),
      _section(
        '二、权限用途说明',
        '为实现相应功能，本应用会按需申请以下敏感权限，'
            '均在您使用对应功能或首次进入主界面时申请，'
            '拒绝授权不影响浏览日记等基本功能使用：\n\n'
            '· 相机 —— 扫描二维码绑定密钥，画面仅本地实时识别，不保存不上传\n'
            '· 图库/相册 —— 从相册导入二维码图片，仅本机解析；'
            '保存导出密钥二维码到相册\n'
            '· 定位 —— 发现局域网 FTP 服务器，不记录不上传\n'
            '· 设备识别码（读取电话状态）—— 获取设备标识用于备份文件绑定校验，不上传\n\n'
            '此外还包括以下非敏感权限：\n'
            '· 网络状态 —— 判断网络可用性，用于备份与更新检测\n'
            '· 生物识别 —— 指纹或 3D 人脸解锁，生物特征由系统管理\n'
            '· 安装应用 —— 安装官方签名的更新包',
      ),
      _section(
        '三、数据存储与保护',
        '1. 令牌密钥使用系统级安全区加密后存储（Android Keystore / iOS Keychain）。\n'
            '2. 本应用开启防截屏保护，防止密钥被第三方截取。\n'
            '3. 复制的密钥文本在 30 秒后自动从剪贴板清除。',
      ),
      _section(
        '四、数据的对外提供',
        '我们不会向任何第三方出售、出租或以其他方式提供您的信息。\n\n'
            '本应用唯一可能对外传输数据的场景是：您主动发起 FTP 备份功能时，'
            '加密后的备份文件将上传至您自行填写和拥有的 FTP 服务器。'
            '该服务器由您控制，我们不参与、不接触该数据。',
      ),
      _section(
        '五、第三方 SDK',
        '本应用不集成任何广告 SDK、统计分析 SDK 或用户画像 SDK。',
      ),
      _section(
        '六、您的权利',
        '· 您可随时在应用内删除任意或全部令牌数据。\n'
            '· 您可随时卸载本应用，卸载后本机全部数据将被清除。\n'
            '· 由于本应用不收集您的个人信息，我们无您的数据可供查询、更正或导出。',
      ),
      _section(
        '七、未成年人保护',
        '本应用为工具类应用，不含任何社交、内容分发或付费功能，适用于全年龄段用户。',
      ),
      _section(
        '八、本政策的更新',
        '若本政策发生重大变更，我们会在应用内以弹窗形式重新征得您的同意。',
      ),
    ];
  }

  Widget _section(String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: BodhiColors.gold,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: BodhiTypography.groupTitle.copyWith(
                  color: BodhiColors.inkBrown,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: BodhiTypography.caption.copyWith(
              fontSize: 12,
              height: 1.85,
              color: BodhiColors.inkGray,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BodhiColors.cardWhite,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('九、联系我们', style: BodhiTypography.groupTitle),
          const SizedBox(height: 8),
          Text(
            '如您对本政策有任何疑问，请通过以下方式联系：\n'
            '邮箱：maodechun@qq.com\n'
            '电话：133307459931\n\n'
            '道拓日记 版权所有',
            style: BodhiTypography.caption.copyWith(
              fontSize: 12,
              height: 1.8,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConsentButtons(BuildContext context) {
    return Column(
      children: [
        Spacer0(),
        GoldButton(
          label: '我已阅读并同意',
          onPressed: onAgree,
        ),
        const SizedBox(height: 10),
        OutlineGoldButton(
          label: '不同意并退出',
          onPressed: onDecline,
        ),
        const SizedBox(height: 8),
        Text(
          '点击「同意」即表示您已阅读并接受本隐私政策的全部内容',
          style: BodhiTypography.caption.copyWith(fontSize: 10),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// 间距占位（避免引入额外组件）
class Spacer0 extends StatelessWidget {
  const Spacer0({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(height: 4);
}
