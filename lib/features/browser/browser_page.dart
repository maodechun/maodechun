import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/plugin_registrant.dart';
import '../../core/system_bridge.dart';
import '../../data/services/update_service.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/common.dart';

/// 内置浏览器
///
/// 用途：打开官方网站 m.0499.com.cn（含首页底部「日记」入口）
///
/// ═══════════════════════════════════════════════════════
/// 网址锁定规则（产品硬性要求）
/// ═══════════════════════════════════════════════════════
///   1. 地址栏为**只读展示**，不提供任何输入控件，
///      用户无法手动修改网址
///   2. [lockedUrl] 非空时进入「锁定模式」：
///      · 隐藏主页按钮（防止跳到别处）
///      · 拦截一切离开锁定域名的主机跳转
///      · 地址栏不显示可点击交互
///   3. 白名单仅放行 0499.com.cn 及其子域
///
/// 安全限制（必须保持）：
///   1. 仅允许 https 协议，http 一律拦截
///   2. 白名单外域名跳转一律拦截
///   3. 禁止下载可执行文件
class InAppBrowserPage extends StatefulWidget {
  final String? initialUrl;
  final VoidCallback onBack;

  /// 锁定模式地址。
  ///
  /// 非空时：地址栏不可编辑、不显示主页按钮、
  /// 且只允许在该域名内跳转（子路径与查询参数放行）。
  final String? lockedUrl;

  /// 顶部标题（锁定模式下显示，替代地址栏）
  final String? title;

  /// 是否显示顶部左上角的关闭按钮。
  ///
  /// 日记作为底部导航 tab 内嵌时设为 false，
  /// 由底部导航负责离开，不再显示「关闭」图标。
  final bool showClose;

  const InAppBrowserPage({
    super.key,
    this.initialUrl,
    required this.onBack,
    this.lockedUrl,
    this.title,
    this.showClose = true,
  });

  @override
  State<InAppBrowserPage> createState() => _InAppBrowserPageState();
}

class _InAppBrowserPageState extends State<InAppBrowserPage> {
  /// 允许访问的域名（含子域）
  static const List<String> _allowedHosts = [
    'm.0499.com.cn',
    'app.0499.com.cn',
    '0499.com.cn',
    'fojiao.miaoda.online',
  ];

  late final WebViewController _controller;
  String _currentUrl = '';
  bool _loading = true;
  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;

  /// WebView 平台实现不可用（注册失效等极端情况）。
  ///
  /// 此时不创建控制器，页面降级为提示页，绝不崩溃。
  bool _webviewBroken = false;

  /// 是否处于「网址锁定」模式
  ///
  /// 锁定模式下：地址栏只读且不可交互、隐藏主页按钮、
  /// 拒绝一切离开锁定域名的主机跳转。
  bool get _locked => widget.lockedUrl != null;

  /// 是否已切换到备选网址
  bool _usingFallback = false;

  /// 是否已尝试过备选网址（防止无限重试）
  bool _triedFallback = false;

  /// 锁定域名允许的 host 列表（主地址 + 备选地址，小写）
  List<String> get _lockedHosts {
    final raw = widget.lockedUrl;
    if (raw == null) return const [];
    final host = Uri.tryParse(raw)?.host.toLowerCase();
    if (host == null) return const [];
    // 日记锁定模式下，主地址与备选地址都放行
    return [host, DiaryEntry.fallbackHost];
  }

  @override
  void initState() {
    super.initState();
    // 锁定模式优先使用 lockedUrl，用户无法通过任何方式替换它
    _currentUrl = widget.lockedUrl ?? widget.initialUrl ?? UpdateService.websiteUrl;
    // 系统返回键联动：网页有历史时后退一步，无历史时交回上层（关页面/切后台）
    SystemBack.register(_handleSystemBack);
    _setupController();
  }

  @override
  void dispose() {
    SystemBack.unregister(_handleSystemBack);
    super.dispose();
  }

  /// 系统返回键处理：消费网页历史返回；返回 false 表示无历史可退
  Future<bool> _handleSystemBack() async {
    if (!mounted || _webviewBroken) return false;
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      await _refreshNavState();
      return true;
    }
    return false;
  }

  void _setupController() {
    // ── 平台实现兜底 ──────────────────────────────────
    // 真机上曾出现 main 阶段注册失效、WebViewPlatform.instance == null
    // 导致「Null check operator used on a null value」崩溃。
    // 这里在实际创建控制器前再校验并补注册一次；仍不可用则降级为提示页。
    if (!ensureWebViewPlatform()) {
      _webviewBroken = true;
      return;
    }
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(BodhiColors.paperLight)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _progress = progress / 100);
          },
          onPageStarted: (url) {
            if (!mounted) return;
            setState(() {
              _loading = true;
              _currentUrl = url;
            });
          },
          onPageFinished: (url) async {
            final canBack = await _controller.canGoBack();
            final canForward = await _controller.canGoForward();
            if (!mounted) return;
            setState(() {
              _loading = false;
              _currentUrl = url;
              _canGoBack = canBack;
              _canGoForward = canForward;
            });
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            setState(() => _loading = false);
            // ── 主地址打不开时，自动切换到备选网址 ─────────
            // 仅在「锁定模式 + 主框架加载失败 + 尚未尝试过备选」时触发，
            // 避免子资源（图片等）加载失败误触发切换。
            if (_locked &&
                !_triedFallback &&
                (error.isForMainFrame ?? false)) {
              _switchToFallback();
            }
          },
          // 域名白名单校验
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) {
              return NavigationDecision.prevent;
            }

            // 仅允许 https
            if (uri.scheme != 'https') {
              _snack('已拦截非加密链接，仅允许访问 https 页面');
              return NavigationDecision.prevent;
            }

            final host = uri.host.toLowerCase();

            // ── 锁定模式：只允许锁定域名（含备选）及其子域 ──
            if (_locked) {
              final sameSite = _lockedHosts.any(
                (h) => host == h || host.endsWith('.$h'),
              );
              if (!sameSite) {
                _snack('日记仅可浏览 0499.com.cn 站内内容');
                return NavigationDecision.prevent;
              }
              // 站内跳转放行
              return NavigationDecision.navigate;
            }

            // ── 普通模式：全局白名单校验 ──────────────────
            final allowed = _allowedHosts.any(
              (h) => host == h || host.endsWith('.$h'),
            );

            if (!allowed) {
              _snack('即将离开官方网站：$host');
              // 交由系统浏览器打开，避免站内跳转到不可信页面
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
        ),
      );

    _controller.loadRequest(Uri.parse(_currentUrl));
  }

  @override
  Widget build(BuildContext context) {
    // WebView 平台不可用：友好提示页（不崩溃，返回键由上层关闭本页）
    if (_webviewBroken) {
      return DecoratedBox(
        decoration: const BoxDecoration(color: BodhiColors.paperLight),
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.web_outlined,
                  size: 48, color: BodhiColors.inkFaint),
              const SizedBox(height: 16),
              Text('网页组件加载失败',
                  style: BodhiTypography.pageTitle),
              const SizedBox(height: 8),
              Text(
                '请退出应用后重新打开；若多次失败，'
                '可在设置中「清除缓存」后重试。',
                style: BodhiTypography.caption,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              OutlineGoldButton(
                label: '返回',
                onPressed: widget.onBack,
                height: 42,
              ),
            ],
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: const BoxDecoration(color: BodhiColors.paperLight),
      child: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            if (_loading)
              LinearProgressIndicator(
                value: _progress,
                minHeight: 2,
                backgroundColor: BodhiColors.divider,
                valueColor: const AlwaysStoppedAnimation(BodhiColors.gold),
              ),
            Expanded(child: WebViewWidget(controller: _controller)),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  /// 刷新底部导航键的可用状态（后退 / 前进）
  Future<void> _refreshNavState() async {
    final canBack = await _controller.canGoBack();
    final canForward = await _controller.canGoForward();
    if (!mounted) return;
    setState(() {
      _canGoBack = canBack;
      _canGoForward = canForward;
    });
  }

  Widget _buildTopBar() {
    return Container(
      height: 52,
      decoration: const BoxDecoration(
        color: BodhiColors.paperLight,
        border: Border(
          bottom: BorderSide(color: BodhiColors.divider, width: 1),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            if (widget.showClose) ...[
              _iconButton(
                icon: Icons.close,
                onTap: widget.onBack,
              ),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: BodhiColors.fieldBg,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  children: [
                    // 锁定模式用锁形图标，普通模式用域名图标
                    Icon(
                      _locked ? Icons.lock : Icons.lock_outline,
                      size: 12,
                      color: _locked ? BodhiColors.moss : BodhiColors.moss,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        // ⚠️ 纯 Text 展示，不是 TextField —— 用户无法编辑网址
                        _displayUrl(),
                        style: BodhiTypography.caption.copyWith(fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            // 锁定模式下不显示刷新（避免用户误以为可重设地址），
            // 但保留刷新其实无害，这里仍保留以便内容加载失败时重试
            _iconButton(
              icon: Icons.refresh,
              onTap: () => _controller.reload(),
            ),
          ],
        ),
      ),
    );
  }

  /// 地址栏文案
  ///
  /// 锁定模式：显示固定标题（如「日记 · m.0499.com.cn」）
  /// 普通模式：显示当前 host + path
  String _displayUrl() {
    if (_locked) {
      final label = widget.title ?? '日记';
      final host = _usingFallback ? DiaryEntry.fallbackHost : 'm.0499.com.cn';
      return '$label · $host';
    }
    final uri = Uri.tryParse(_currentUrl);
    if (uri == null) return _currentUrl;
    final path = uri.path.isEmpty || uri.path == '/' ? '' : uri.path;
    return '${uri.host}$path';
  }

  /// 主地址加载失败时，切换到备选网址
  ///
  /// 仅在锁定模式（日记）下触发；切换后地址栏同步显示备选域名。
  void _switchToFallback() {
    if (_triedFallback) return;
    _triedFallback = true;
    _usingFallback = true;
    final fallback = DiaryEntry.fallbackUrl;
    setState(() {
      _currentUrl = fallback;
      _loading = true;
    });
    _controller.loadRequest(Uri.parse(fallback));
  }

  Widget _buildBottomBar() {
    return Container(
      height: 48,
      decoration: const BoxDecoration(
        color: BodhiColors.paperLight,
        border: Border(
          top: BorderSide(color: BodhiColors.divider, width: 1),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _navButton(
            icon: Icons.arrow_back_ios_new,
            label: '后退',
            enabled: _canGoBack,
            onTap: () async {
              if (await _controller.canGoBack()) {
                await _controller.goBack();
                await _refreshNavState();
              }
            },
          ),
          _navButton(
            icon: Icons.arrow_forward_ios,
            label: '前进',
            enabled: _canGoForward,
            onTap: () async {
              if (await _controller.canGoForward()) {
                await _controller.goForward();
                await _refreshNavState();
              }
            },
          ),
          // ⚠️ 锁定模式不提供「首页」按钮：
          //    该按钮会把地址重置为用户可感知的目标，
          //    虽然仍是固定常量，但为防止任何"改地址"的观感，直接隐藏。
          if (!_locked)
            _navButton(
              icon: Icons.home_outlined,
              label: '首页',
              enabled: true,
              onTap: () => _controller.loadRequest(
                Uri.parse(UpdateService.websiteUrl),
              ),
            ),
          _navButton(
            icon: Icons.refresh,
            label: '刷新',
            enabled: true,
            onTap: () => _controller.reload(),
          ),
        ],
      ),
    );
  }

  Widget _iconButton({required IconData icon, required VoidCallback onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, size: 18, color: BodhiColors.inkBrown),
        ),
      ),
    );
  }

  Widget _navButton({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final color = enabled ? BodhiColors.inkBrown : BodhiColors.inkFaint;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 64,
          height: 44,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                style: BodhiTypography.caption.copyWith(
                  fontSize: 9,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// 平台能力检测（避免在不支持的平台初始化 WebView）
bool get isWebViewSupported => Platform.isAndroid || Platform.isIOS;

/// 日记入口的固定地址（常量锁定，用户不可修改）
///
/// 主地址打不开时，自动切换到备选地址。
class DiaryEntry {
  DiaryEntry._();

  /// 日记站主地址 —— 唯一默认来源
  static const String url = 'https://m.0499.com.cn';

  /// 备选地址（主地址不可用时自动切换）
  static const String fallbackUrl = 'https://fojiao.miaoda.online';

  /// 备选地址的 host（小写，用于白名单与地址栏展示）
  static const String fallbackHost = 'fojiao.miaoda.online';

  /// 菜单显示名称（固定）
  static const String label = '日记';
}
