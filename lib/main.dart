import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/audio/background_music.dart';
import 'core/auto_lock_guard.dart';
import 'core/permissions/permission_service.dart';
import 'core/plugin_registrant.dart';
import 'core/security/secret_store.dart';
import 'core/system_bridge.dart';
import 'core/time/ntp_client.dart';
import 'data/models/token.dart';
import 'data/repository/token_repository.dart';
import 'data/services/qiniu_backup_service.dart';
import 'data/services/update_service.dart';
import 'features/browser/browser_page.dart';
import 'features/export/export_page.dart';
import 'features/legal/privacy_page.dart';
import 'features/lock/setup_password_page.dart';
import 'features/lock/unlock_page.dart';
import 'features/scan/scan_page.dart';
import 'features/settings/settings_page.dart';
import 'features/splash/splash_page.dart';
import 'features/token_list/token_list_page.dart';
import 'theme/colors.dart';
import 'theme/typography.dart';
import 'widgets/common.dart';

/// 启动期诊断信息：任何初始化错误都会记录于此并显示在屏幕上，
/// 便于无日志环境下通过截图定位崩溃原因。
class StartupDiag {
  static String? error;
  static String? stack;
  static final List<String> steps = [];

  /// WebView 平台实现是否注册成功（真机排障关键项）
  static bool? webviewReady;

  /// 初始化是否已完成。
  /// 完成之后运行期出现的异步错误（如扫码组件内部异常）只记日志，
  /// 绝不再劫持整个界面——此前任何 zone 错误都会把 app 锁死在诊断页，
  /// 表现为「整个应用卡在启动异常、按什么都没反应」。
  static bool booted = false;

  /// 核心初始化（安全存储 / 数据库）失败——真正的致命错误才显示诊断页
  static bool fatal = false;

  /// 与 pubspec.yaml version 保持一致（诊断页展示用）
  static const String appVersion = 'v5.3.9';
}

Future<void> main() async {
  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    registerDartPlugins();
    // 启动即校验并兜底注册 WebView 平台实现，结果写入黑匣子
    StartupDiag.webviewReady = ensureWebViewPlatform();
    FlutterError.onError = (details) {
      if (!StartupDiag.booted) {
        StartupDiag.error ??= details.exceptionAsString();
        StartupDiag.stack ??= details.stack.toString();
      } else {
        // 初始化完成后：运行期错误只记日志（logcat tag=flutter 可查），
        // 不再劫持界面（例如扫码组件的 ML Kit 内部异常）
        print('[BodhiFlutterError] ${details.exceptionAsString()}');
      }
    };

    // 界面先跑起来，重初始化全部延后且带兜底，
    // 任何失败都不再导致秒退，而是显示诊断页。
    runApp(const BodhiApp());
  }, (error, stack) {
    if (!StartupDiag.booted) {
      StartupDiag.error ??= error.toString();
      StartupDiag.stack ??= stack.toString();
    } else {
      print('[BodhiZone] runtime error: $error');
    }
  });
}

class BodhiApp extends StatelessWidget {
  const BodhiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '菩提护令',
      debugShowCheckedModeBanner: false,
      theme: BodhiTheme.light(),
      // 限制系统字体缩放，避免破坏古风排版
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler.clamp(
              minScaleFactor: 0.9,
              maxScaleFactor: 1.15,
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const AppShell(),
    );
  }
}

/// 应用壳层
///
/// 负责：
///   - 首次启动隐私政策拦截
///   - 启动页 → 锁屏 → 解锁 → 主界面的流程编排
///   - 各设置项的持久化与全局状态
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

/// 应用阶段
enum AppPhase {
  privacyConsent, // 隐私政策同意
  splash,         // 启动页
  setupPassword,  // 首次使用：用户自行设定启动密码
  lockCover,      // 锁屏遮罩
  unlock,         // 解锁
  main,           // 主界面
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  AppPhase _phase = AppPhase.splash;
  bool _booted = false;
  bool _orientationLocked = false;

  // 安全开关
  bool _passwordEnabled = true;
  bool _fingerprintEnabled = true;
  bool _faceEnabled = false;
  bool _voiceEnabled = true;

  /// 密码哈希（不明文存储）
  String? _passwordHash;

  // 子页面栈（用 Navigator 管理更合适，此处用简单状态切换）
  Token? _exportToken;
  bool _showBrowser = false;
  bool _showPrivacy = false;

  Timer? _updateTimer;
  DateTime? _pausedAt;

  /// 权限引导是否已展示过（每次启动只引导一次）
  bool _permissionPromptShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updateTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
      BackgroundMusic.instance.pauseForBackground();
    } else if (state == AppLifecycleState.resumed) {
      final paused = _pausedAt;
      // 超过 30 秒回到前台需重新解锁（安全要求）。
      // 备份/恢复等跨页面流程期间挂起（AutoLockGuard.suspended），
      // 否则 SAF 文件选择器超 30 秒会卸载设置页、令流程静默中止。
      if (paused != null &&
          DateTime.now().difference(paused).inSeconds >= 30 &&
          _phase == AppPhase.main &&
          !AutoLockGuard.suspended) {
        setState(() {
          _pausedAt = null;
          _phase = _passwordEnabled || _fingerprintEnabled || _faceEnabled
              ? AppPhase.lockCover
              : AppPhase.main;
        });
      }
      if (_phase == AppPhase.main) {
        BackgroundMusic.instance.resumeIfEnabled();
      }
      _pausedAt = null;
    }
  }

  // ── 启动流程 ─────────────────────────────────────────

  Future<void> _bootstrap() async {
    try {
      StartupDiag.steps.add('orientation');
      if (!_orientationLocked) {
        _orientationLocked = true;
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
      }

      StartupDiag.steps.add('secret-store');
      await SecretStore.instance.init();

      StartupDiag.steps.add('token-repository');
      await TokenRepository.instance.init();

      NtpClient.instance.syncInBackground();
    } catch (e, st) {
      // 核心初始化失败才是致命错误（需要诊断页）
      StartupDiag.fatal = true;
      StartupDiag.error ??= e.toString();
      StartupDiag.stack ??= st.toString();
    }

    try {
      StartupDiag.steps.add('preferences');
      final prefs = await SharedPreferences.getInstance();

      // 读取用户设置
      _passwordEnabled = prefs.getBool('security_password') ?? true;
      _fingerprintEnabled = prefs.getBool('security_fingerprint') ?? true;
      _faceEnabled = prefs.getBool('security_face') ?? false;
      _voiceEnabled = prefs.getBool('voice_splash') ?? true;
      _passwordHash = prefs.getString('unlock_password_hash');

      // 隐私政策同意检查（合规要求：未同意不得进入）
      final privacyVersion = prefs.getString('privacy_agreed_version') ?? '';
      const currentPrivacyVersion = 'v1.1';
      final agreed = privacyVersion == currentPrivacyVersion;

      if (!mounted) return;
      setState(() {
        _phase = agreed ? AppPhase.splash : AppPhase.privacyConsent;
        _booted = true;
        StartupDiag.booted = true;
      });

      // 启动后延迟静默检查更新
      _scheduleUpdateCheck();
    } catch (e, st) {
      StartupDiag.fatal = true;
      StartupDiag.error ??= e.toString();
      StartupDiag.stack ??= st.toString();
      if (!mounted) return;
      setState(() {
        _booted = true;
        StartupDiag.booted = true;
      });
    }
  }

  /// 启动诊断页：任何初始化失败都会落到这里，
  /// 完整显示错误与堆栈，方便截图反馈定位。
  Widget _buildDiag() {
    final err = StartupDiag.error ?? '未知错误';
    final st = StartupDiag.stack ?? '';
    final steps = StartupDiag.steps.join(' → ');
    return Scaffold(
      backgroundColor: const Color(0xFFFAF5EB),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline, size: 40,
                  color: Color(0xFFB4552D)),
              const SizedBox(height: 16),
              const Text('启动异常（请截图反馈）',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF3B2F22))),
              const SizedBox(height: 12),
              Text('已完成步骤：$steps',
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF6B5D4A))),
              const SizedBox(height: 12),
              Text(
                'WebView组件：${StartupDiag.webviewReady == true ? "正常" : "注册失败"}'
                ' · 版本：${StartupDiag.appVersion}',
                style: const TextStyle(
                    fontSize: 13, color: Color(0xFF6B5D4A)),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    '错误：$err\n\n堆栈：\n$st',
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF3B2F22)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              OutlineGoldButton(
                label: '重试初始化',
                icon: Icons.refresh,
                onPressed: _retryBoot,
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  /// 诊断页重试：清空错误现场，重新执行启动流程
  void _retryBoot() {
    StartupDiag.error = null;
    StartupDiag.stack = null;
    StartupDiag.fatal = false;
    StartupDiag.steps.clear();
    setState(() => _booted = false);
    _bootstrap();
  }

  void _scheduleUpdateCheck() {
    _updateTimer?.cancel();
    _updateTimer = Timer(const Duration(seconds: 3), () async {
      final info = await UpdateService.instance.check(silent: true);
      if (info == null || !mounted) return;
      if (_phase != AppPhase.main) return;

      // 强制更新：弹出不可绕过的弹窗
      _showUpdateDialog(info);
    });
  }

  void _showUpdateDialog(UpdateInfo info) {
    // 交由设置页的弹窗逻辑处理（此处做最简实现）
    showDialog<void>(
      context: context,
      barrierDismissible: !info.forceUpdate,
      builder: (context) {
        return PopScope(
          canPop: !info.forceUpdate,
          child: AlertDialog(
            backgroundColor: const Color(0xFFFFFFFF),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            title: Text('发现新版本 ${info.versionName}'.trim()),
            content: Text(
              info.notesList.isEmpty
                  ? '本次更新修复了若干问题并优化了使用体验。'
                  : info.notesList.join('\n'),
            ),
            actions: [
              if (!info.forceUpdate)
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('稍后'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('立即更新'),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── 隐私政策 ─────────────────────────────────────────

  Future<void> _agreePrivacy() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('privacy_agreed_version', 'v1.1');
    if (!mounted) return;
    setState(() => _phase = AppPhase.splash);
  }

  Future<void> _declinePrivacy() async {
    // 不同意则退出应用
    await SystemNavigator.pop();
  }

  // ── 解锁流程 ─────────────────────────────────────────

  /// 校验密码
  ///
  /// 密码不存明文，存储 SHA-256 哈希。
  /// 未设置过密码时一律校验失败——首次使用由 SetupPasswordPage 引导设定，
  /// 不再「输入即设定」（旧版行为已按产品要求移除）。
  Future<bool> _verifyPassword(String input) async {
    final stored = _passwordHash;
    if (stored == null || stored.isEmpty) return false;
    return _hashPassword(input) == stored;
  }

  /// 首次设定启动密码（SetupPasswordPage 回调）
  Future<void> _onSetupPassword(String password) async {
    final hash = _hashPassword(password);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('unlock_password_hash', hash);
    _passwordHash = hash;
    if (!mounted) return;
    setState(() => _phase = AppPhase.main);
    _schedulePermissionPrompt();
    BackgroundMusic.instance.ensureStarted();
  }

  /// 修改启动密码（设置页回调：先验证旧密码，再保存新密码）
  ///
  /// 成功返回 null；失败返回错误文案。
  Future<String?> _changePassword(String oldPwd, String newPwd) async {
    final stored = _passwordHash;
    if (stored != null && stored.isNotEmpty &&
        _hashPassword(oldPwd) != stored) {
      return '当前密码不正确';
    }
    if (newPwd.length != 6 || int.tryParse(newPwd) == null) {
      return '新密码需为 6 位数字';
    }
    if (newPwd == oldPwd) return '新密码不能与当前密码相同';
    final hash = _hashPassword(newPwd);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('unlock_password_hash', hash);
    _passwordHash = hash;
    return null;
  }

  String _hashPassword(String input) {
    // 加盐后做 SHA-256，避免明文存储
    final bytes = utf8.encode('bodhi_salt_v1_$input');
    return base64Encode(sha256.convert(bytes).bytes);
  }

  // ── 设置项持久化 ─────────────────────────────────────

  Future<void> _onSecurityChanged(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    switch (key) {
      case 'password':
        await prefs.setBool('security_password', value);
        _passwordEnabled = value;
        // 重新开启密码锁定但从未设定过密码：立即进入设定流程，
        // 避免「开关已开却没有密码可验」的死锁
        if (value && (_passwordHash == null || _passwordHash!.isEmpty)) {
          if (mounted) setState(() => _phase = AppPhase.setupPassword);
        }
        break;
      case 'fingerprint':
        await prefs.setBool('security_fingerprint', value);
        _fingerprintEnabled = value;
        break;
      case 'face':
        await prefs.setBool('security_face', value);
        _faceEnabled = value;
        break;
    }
    if (mounted) setState(() {});
  }

  Future<void> _onVoiceChanged(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('voice_splash', value);
    if (mounted) setState(() => _voiceEnabled = value);
  }

  /// 开屏问候语播报完毕 —— 按安全设置决定下一屏。
  /// 首次使用（密码锁定开启且未设定密码）：先进「设置启动密码」页，
  /// 由用户自行设定，不再「输入即设定」。
  void _onSplashFinished() {
    if (!mounted) return;
    if (_passwordEnabled &&
        (_passwordHash == null || _passwordHash!.isEmpty)) {
      setState(() => _phase = AppPhase.setupPassword);
      return;
    }
    final needLock =
        _passwordEnabled || _fingerprintEnabled || _faceEnabled;
    setState(() {
      _phase = needLock ? AppPhase.lockCover : AppPhase.main;
    });
    if (!needLock) {
      _schedulePermissionPrompt();
      BackgroundMusic.instance.ensureStarted();
    }
  }

  /// 进入主界面后引导用户开启必要权限（每次启动仅一次）
  void _schedulePermissionPrompt() {
    if (_permissionPromptShown) return;
    _permissionPromptShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showPermissionDialog();
    });
  }

  /// 权限申请引导弹窗
  ///
  /// 合规要求：先展示用途说明，用户同意后再逐项申请系统权限，
  /// 不直接弹出系统权限框。
  Future<void> _showPermissionDialog() async {
    try {
      final missing =
          await PermissionService.instance.hasMissingPermissions();
      if (!missing || !mounted) return;
    } catch (_) {
      return;
    }
    if (!mounted) return;

    final agreed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return AlertDialog(
          backgroundColor: BodhiColors.cardWhite,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              const Icon(
                Icons.verified_user_outlined,
                size: 20,
                color: BodhiColors.gold,
              ),
              const SizedBox(width: 8),
              Text('开启必要权限', style: BodhiTypography.pageTitle),
            ],
          ),
          content: Text(
            '为正常使用以下功能，需要申请相应权限：\n\n'
            '· 相机 —— 扫描二维码绑定令牌\n'
            '· 图库 —— 从相册导入二维码图片\n'
            '· 定位 —— 发现局域网 FTP 服务器\n'
            '· 设备识别码 —— 备份文件绑定校验\n\n'
            '以上权限仅用于上述功能，拒绝不影响浏览日记等基本使用。',
            style: BodhiTypography.body.copyWith(
              color: BodhiColors.inkGray,
              height: 1.7,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                '暂不',
                style: BodhiTypography.rowLabel.copyWith(
                  color: BodhiColors.inkGray,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                '允许',
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

    if (agreed == true) {
      final result = await PermissionService.instance.requestAll();
      final stillMissing = result.values.any((granted) => !granted);
      if (stillMissing && mounted) {
        // 权限未全开：很可能此前拒绝时触发了「不再询问」，
        // 系统不会再弹窗，只能引导去系统设置手动开启
        final goSettings = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              backgroundColor: BodhiColors.cardWhite,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 20,
                    color: BodhiColors.gold,
                  ),
                  const SizedBox(width: 8),
                  Text('部分权限未开启', style: BodhiTypography.pageTitle),
                ],
              ),
              content: Text(
                '相机 / 相册 / 定位 / 设备识别码中仍有未开启的权限。\n\n'
                '若您此前拒绝过且选择了「不再询问」，系统将不再弹出申请，'
                '需要到系统设置中手动开启，否则扫码、相册导入等功能无法使用。',
                style: BodhiTypography.body.copyWith(
                  color: BodhiColors.inkGray,
                  height: 1.7,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(
                    '暂不',
                    style: BodhiTypography.rowLabel.copyWith(
                      color: BodhiColors.inkGray,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(
                    '去系统设置开启',
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
        if (goSettings == true && mounted) {
          await PermissionService.instance.openSettings();
        }
      }
    }
  }

  // ── 构建 ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // 系统返回键（底部虚拟导航键）全局接管：
    //   1. 最上层页面优先响应（浏览器网页后退 / 扫码与设置返回令牌页）
    //   2. 无人认领时：关闭子页 / 应用切后台（不杀进程）
    // 此前主界面不是 Navigator 路由栈，系统返回键无路可退，表现为完全无效。
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        if (await SystemBack.dispatch()) return;
        _handleRootBack();
      },
      child: _buildPhase(),
    );
  }

  /// 根级返回兜底：关闭子页，或把应用切到后台（等同 Home 键，不杀进程）
  void _handleRootBack() {
    if (_showPrivacy) {
      setState(() => _showPrivacy = false);
      return;
    }
    if (_showBrowser) {
      setState(() => _showBrowser = false);
      return;
    }
    if (_exportToken != null) {
      setState(() => _exportToken = null);
      return;
    }
    SystemBridge.moveTaskToBack().catchError((_) {
      // 通道不可用（极端情况）：保持当前页面，不强制退出
    });
  }

  Widget _buildPhase() {
    // 子页面优先展示
    if (_showPrivacy) {
      return PrivacyPolicyPage(
        consentMode: false,
        onAgree: null,
        onDecline: null,
      );
    }
    if (_showBrowser) {
      return InAppBrowserPage(
        // 设置页「打开官网」：普通浏览模式（不锁定，白名单内自由浏览）
        initialUrl: UpdateService.websiteUrl,
        onBack: () => setState(() => _showBrowser = false),
      );
    }
    if (_exportToken != null) {
      return ExportPage(
        token: _exportToken!,
        onBack: () => setState(() => _exportToken = null),
      );
    }

    // 核心初始化失败（或完成前出错）：显示诊断页而不是闪退。
    // 运行期普通错误不再进入这里（只记日志，不劫持界面）。
    if (StartupDiag.fatal || (StartupDiag.error != null && !_booted)) {
      return _buildDiag();
    }
    if (!_booted) {
      // 初始化进行中：显示极简加载页
      return const Scaffold(
        backgroundColor: Color(0xFFFAF5EB),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFFB7932F)),
        ),
      );
    }

    switch (_phase) {
      case AppPhase.privacyConsent:
        return PrivacyPolicyPage(
          consentMode: true,
          onAgree: _agreePrivacy,
          onDecline: _declinePrivacy,
        );

      case AppPhase.splash:
        return SplashPage(
          voiceEnabled: _voiceEnabled,
          onFinished: _onSplashFinished,
        );

      case AppPhase.setupPassword:
        return SetupPasswordPage(onSet: _onSetupPassword);

      case AppPhase.lockCover:
        return LockCoverPage(
          biometricEnabled: _fingerprintEnabled || _faceEnabled,
          onUnlock: () => setState(() => _phase = AppPhase.unlock),
        );

      case AppPhase.unlock:
        return UnlockPage(
          passwordEnabled: _passwordEnabled,
          fingerprintEnabled: _fingerprintEnabled,
          faceEnabled: _faceEnabled,
          verifyPassword: _verifyPassword,
          onUnlocked: () {
            setState(() => _phase = AppPhase.main);
            _schedulePermissionPrompt();
            BackgroundMusic.instance.ensureStarted();
          },
        );

      case AppPhase.main:
        return _buildMain();
    }
  }

  /// 主界面（含扫码 / 设置的子页面切换）
  Widget _buildMain() {
    return _MainNavigator(
      onExport: (token) => setState(() => _exportToken = token),
      // 设置页「打开官网」：普通浏览模式（无锁定）
      onOpenBrowser: () => setState(() => _showBrowser = true),
      onOpenPrivacy: () => setState(() => _showPrivacy = true),
      passwordEnabled: _passwordEnabled,
      fingerprintEnabled: _fingerprintEnabled,
      faceEnabled: _faceEnabled,
      voiceEnabled: _voiceEnabled,
      onSecurityChanged: _onSecurityChanged,
      onVoiceChanged: _onVoiceChanged,
      verifyPassword: _verifyPassword,
      onChangePassword: _changePassword,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }
}

/// 主界面导航（日记 ↔ 令牌 ↔ 设置，扫码为全屏子页）
///
/// 底部导航顺序固定为「日记 · 令牌 · 设置」，日记居左第一项，
/// 且默认打开日记页。
class _MainNavigator extends StatefulWidget {
  final void Function(Token token) onExport;
  final VoidCallback onOpenBrowser;
  final VoidCallback onOpenPrivacy;
  final bool passwordEnabled;
  final bool fingerprintEnabled;
  final bool faceEnabled;
  final bool voiceEnabled;
  final void Function(String key, bool value) onSecurityChanged;
  final void Function(bool value) onVoiceChanged;

  /// 启动密码校验与修改（由主壳层提供）
  final Future<bool> Function(String input) verifyPassword;
  final Future<String?> Function(String oldPwd, String newPwd) onChangePassword;

  const _MainNavigator({
    required this.onExport,
    required this.onOpenBrowser,
    required this.onOpenPrivacy,
    required this.passwordEnabled,
    required this.fingerprintEnabled,
    required this.faceEnabled,
    required this.voiceEnabled,
    required this.onSecurityChanged,
    required this.onVoiceChanged,
    required this.verifyPassword,
    required this.onChangePassword,
  });

  @override
  State<_MainNavigator> createState() => _MainNavigatorState();
}

/// 主路由（底部导航的三项 + 全屏扫码页）
enum _MainRoute { diary, tokens, settings, scan }

class _MainNavigatorState extends State<_MainNavigator> {
  /// 默认打开日记（左边第一项）
  _MainRoute _route = _MainRoute.diary;

  @override
  void initState() {
    super.initState();
    // 系统返回键：扫码 / 设置 → 令牌页；日记与令牌页交回根壳层（切后台）
    SystemBack.register(_handleSystemBack);
  }

  @override
  void dispose() {
    SystemBack.unregister(_handleSystemBack);
    super.dispose();
  }

  Future<bool> _handleSystemBack() async {
    if (_route == _MainRoute.scan || _route == _MainRoute.settings) {
      setState(() => _route = _MainRoute.tokens);
      return true;
    }
    // 日记（网页历史后退由浏览器处理器认领）/ 令牌页：交回根壳层
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // 扫码页：全屏，不显示底部导航
    if (_route == _MainRoute.scan) {
      return _buildScan();
    }

    return Column(
      children: [
        Expanded(child: _buildContent()),
        _MainBottomBar(
          current: _route,
          onSelect: (r) => setState(() => _route = r),
        ),
      ],
    );
  }

  Widget _buildContent() {
    switch (_route) {
      case _MainRoute.diary:
        return InAppBrowserPage(
          lockedUrl: DiaryEntry.url,
          title: DiaryEntry.label,
          showClose: false,
          // 网页无历史可退时，返回键切到令牌页
          onBack: () => setState(() => _route = _MainRoute.tokens),
        );

      case _MainRoute.tokens:
        return TokenListPage(
          onAddToken: () => setState(() => _route = _MainRoute.scan),
          onExport: widget.onExport,
          onOpenSettings: () => setState(() => _route = _MainRoute.settings),
        );

      case _MainRoute.settings:
        return SettingsPage(
          onBack: () => setState(() => _route = _MainRoute.tokens),
          onOpenBrowser: widget.onOpenBrowser,
          onOpenPrivacy: widget.onOpenPrivacy,
          onVoiceChanged: widget.onVoiceChanged,
          passwordEnabled: widget.passwordEnabled,
          fingerprintEnabled: widget.fingerprintEnabled,
          faceEnabled: widget.faceEnabled,
          voiceEnabled: widget.voiceEnabled,
          onSecurityChanged: widget.onSecurityChanged,
          verifyPassword: widget.verifyPassword,
          onChangePassword: widget.onChangePassword,
        );

      case _MainRoute.scan:
        return const SizedBox.shrink();
    }
  }

  Widget _buildScan() {
    return ScanPage(
      onBack: () => setState(() => _route = _MainRoute.tokens),
      onBound: (items, {bool? keepScanning}) async {
        // Google 令牌迁移二维码一次可携带多个账号，逐条落库并汇总结果
        var added = 0;
        var duplicated = 0;
        var failed = 0;
        String? lastError;

        for (final data in items) {
          final result = await TokenRepository.instance.addFromOtpAuth(data);
          if (result.success) {
            added++;
          } else if (result.duplicated) {
            duplicated++;
          } else {
            failed++;
            lastError = result.error;
          }
        }

        if (!mounted) return;

        final parts = <String>[];
        if (added > 0) {
          parts.add(added == 1 ? '密钥绑定成功' : '成功导入 $added 个令牌');
        }
        if (duplicated > 0) {
          parts.add(added > 0
              ? '$duplicated 个已存在'
              : (duplicated == 1 ? '该令牌已存在，无需重复添加' : '$duplicated 个令牌均已存在'));
        }
        if (failed > 0) {
          parts.add('$failed 个导入失败');
        }

        // 分批二维码（Google 账号较多时会拆成多张）：还有下一张时留在
        // 扫码页，让用户立即接着扫。此时「请继续扫描下一页二维码」的提示
        // 由扫码页统一给出，这里不重复弹（否则会把它盖掉）；
        // 但导入失败必须让用户看见，不能被「请继续」盖住。
        if (keepScanning == true) {
          if (failed > 0) {
            _toast(parts.join('，'));
          }
          return;
        }

        // 最后一张（或单张）导入完成：回到令牌列表并汇总结果
        setState(() => _route = _MainRoute.tokens);
        _toast(parts.isNotEmpty ? parts.join('，') : (lastError ?? '绑定失败'));
        // 绑定成功后自动云备份（已绑定手机号时），结果明确告知用户
        if (added > 0) {
          final savedPhone = await QiniuBackupService.instance.getPhone();
          if (savedPhone != null) {
            final r = await QiniuBackupService.instance.backup(savedPhone);
            if (!mounted) return;
            _toast(r.success
                ? '✅ 云备份成功：令牌已加密上传到云端（$savedPhone）'
                : '⚠️ 自动云备份未完成：${r.message}');
          }
        }
      },
    );
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: BodhiTypography.caption.copyWith(
            color: const Color(0xFFFAF5EB),
          ),
        ),
        backgroundColor: const Color(0xFF3B2F22),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// 底部导航 tab
enum _BottomTab { diary, tokens, settings }

/// 主界面底部固定导航栏
///
/// ⚠️ 产品约束（硬性要求，任何改动不得破坏）：
///   1. 顺序固定为「日记 / 令牌 / 设置」，日记居左第一项
///   2. 「日记」为固定项：不可删除、隐藏、重命名、编辑网址
///   3. 「日记」跳转地址由 DiaryEntry.url 锁定（主地址不可用自动切备选）
class _MainBottomBar extends StatelessWidget {
  final _MainRoute current;
  final void Function(_MainRoute route) onSelect;

  const _MainBottomBar({
    required this.current,
    required this.onSelect,
  });

  _BottomTab _tabOf(_MainRoute route) {
    switch (route) {
      case _MainRoute.diary:
        return _BottomTab.diary;
      case _MainRoute.tokens:
      case _MainRoute.scan:
        return _BottomTab.tokens;
      case _MainRoute.settings:
        return _BottomTab.settings;
    }
  }

  _MainRoute _routeOf(_BottomTab tab) {
    switch (tab) {
      case _BottomTab.diary:
        return _MainRoute.diary;
      case _BottomTab.tokens:
        return _MainRoute.tokens;
      case _BottomTab.settings:
        return _MainRoute.settings;
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeTab = _tabOf(current);
    return Container(
      decoration: const BoxDecoration(
        color: BodhiColors.paperLight,
        border: Border(
          top: BorderSide(color: BodhiColors.divider, width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              _item(
                tab: _BottomTab.diary,
                icon: Icons.auto_stories_outlined,
                label: DiaryEntry.label,
                active: activeTab == _BottomTab.diary,
                accent: BodhiColors.moss,
              ),
              _item(
                tab: _BottomTab.tokens,
                icon: Icons.grid_view_rounded,
                label: '令牌',
                active: activeTab == _BottomTab.tokens,
              ),
              _item(
                tab: _BottomTab.settings,
                icon: Icons.settings_outlined,
                label: '设置',
                active: activeTab == _BottomTab.settings,
              ),
              // 背景音乐开关（《云水禅心》）：非导航 tab，独立控制按钮
              const _MusicToggleButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item({
    required _BottomTab tab,
    required IconData icon,
    required String label,
    required bool active,
    Color? accent,
  }) {
    final Color base = accent ?? BodhiColors.inkBrown;
    final Color color = active ? base : BodhiColors.inkFaint;

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => onSelect(_routeOf(tab)),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                height: 3,
                child: active
                    ? Container(
                        width: 16,
                        decoration: BoxDecoration(
                          color: base,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      )
                    : null,
              ),
              const SizedBox(height: 5),
              Icon(icon, size: 21, color: color),
              const SizedBox(height: 3),
              Text(
                label,
                style: BodhiTypography.caption.copyWith(
                  fontSize: 11,
                  color: color,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 背景音乐（《云水禅心》）暂停 / 播放按钮
///
/// 位于底部导航栏最右侧，独立于「日记 / 令牌 / 设置」三个固定 tab，
/// 不参与路由切换。点按切换播放状态，图标随之变化。
class _MusicToggleButton extends StatefulWidget {
  const _MusicToggleButton();

  @override
  State<_MusicToggleButton> createState() => _MusicToggleButtonState();
}

class _MusicToggleButtonState extends State<_MusicToggleButton> {
  bool _on = BackgroundMusic.instance.enabled;

  @override
  Widget build(BuildContext context) {
    final Color color = _on ? BodhiColors.moss : BodhiColors.inkFaint;
    return SizedBox(
      width: 52,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () async {
            await BackgroundMusic.instance.setEnabled(!_on);
            if (mounted) setState(() => _on = BackgroundMusic.instance.enabled);
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _on ? Icons.music_note_rounded : Icons.music_off_rounded,
                size: 21,
                color: color,
              ),
              const SizedBox(height: 3),
              Text(
                '音乐',
                style: BodhiTypography.caption.copyWith(
                  fontSize: 11,
                  color: color,
                  fontWeight: _on ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
