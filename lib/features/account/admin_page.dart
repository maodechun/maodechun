import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/common.dart';
import 'account_api.dart';
import 'admin_bridge.dart';
import 'email_bridge.dart';

/// 超级管理员 · 后台管理页
///
/// 进入本页前必须先通过本地管理员校验（关于页底部入口）。
/// 页面内所有数据均来自服务端管理接口，需携带管理员会话令牌。
///
/// Tab：
///   - 用户：注册用户统计与列表
///   - 日志：用户登录日志 + 管理端操作审计
/// 工具：
///   - 邮件接口测试：通过原生 SMTP 引擎发送测试邮件
class AdminPage extends StatefulWidget {
  const AdminPage({super.key});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage>
    with SingleTickerProviderStateMixin {
  final AccountApi _api = AccountApi.instance;
  late final TabController _tab = TabController(length: 2, vsync: this);

  // 用户列表状态
  bool _loading = true;
  String? _error;
  int _total = 0;
  int _page = 1;
  bool _hasMore = false;
  final List<AdminUserItem> _users = [];
  final _searchController = TextEditingController();

  // 日志状态
  bool _logLoading = false;
  String? _logError;
  int _logTotal = 0;
  int _logPage = 1;
  bool _logHasMore = false;
  final List<AdminLogItem> _logs = [];

  @override
  void initState() {
    super.initState();
    _refresh();
    _tab.addListener(() {
      if (_tab.index == 1 && _logs.isEmpty && !_logLoading) _refreshLogs();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tab.dispose();
    super.dispose();
  }

  String? get _token => AdminBridge.instance.sessionToken;

  Future<void> _refresh() async {
    final token = _token;
    if (token == null) {
      setState(() {
        _loading = false;
        _error = '管理员会话已失效，请重新登录';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _api.adminUsers(token, page: 1, pageSize: 20);
      if (!mounted) return;
      setState(() {
        _users
          ..clear()
          ..addAll(list.users);
        _total = list.total;
        _page = 1;
        _hasMore = _users.length < _total;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // 令牌失效时服务端会给出可读原因
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '无法连接服务器，请检查网络后重试';
      });
    }
  }

  Future<void> _loadMore() async {
    final token = _token;
    if (token == null || !_hasMore || _loading) return;
    setState(() => _loading = true);
    try {
      final list = await _api.adminUsers(token,
          page: _page + 1, pageSize: 20);
      if (!mounted) return;
      setState(() {
        _users.addAll(list.users);
        _page = list.page;
        _hasMore = _users.length < _total;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showSnack('加载更多失败，请稍后重试');
    }
  }

  // ── 登录日志 / 操作审计 ────────────────────────────────

  Future<void> _refreshLogs() async {
    final token = _token;
    if (token == null) {
      setState(() {
        _logLoading = false;
        _logError = '管理员会话已失效，请重新登录';
      });
      return;
    }
    setState(() {
      _logLoading = true;
      _logError = null;
    });
    try {
      final list = await _api.adminLogs(token, page: 1, pageSize: 30);
      if (!mounted) return;
      setState(() {
        _logs
          ..clear()
          ..addAll(list.logs);
        _logTotal = list.total;
        _logPage = 1;
        _logHasMore = _logs.length < _logTotal;
        _logLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _logLoading = false;
        _logError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _logLoading = false;
        _logError = '无法连接服务器，请检查网络后重试';
      });
    }
  }

  Future<void> _loadMoreLogs() async {
    final token = _token;
    if (token == null || !_logHasMore || _logLoading) return;
    setState(() => _logLoading = true);
    try {
      final list =
          await _api.adminLogs(token, page: _logPage + 1, pageSize: 30);
      if (!mounted) return;
      setState(() {
        _logs.addAll(list.logs);
        _logPage = list.page;
        _logHasMore = _logs.length < _logTotal;
        _logLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _logLoading = false);
    }
  }

  // ── 邮件接口测试（原生 SMTP 直发） ─────────────────────

  Future<void> _smtpTest() async {
    final token = _token;
    if (token == null) {
      _showSnack('管理员会话已失效，请重新登录');
      return;
    }
    final controller = TextEditingController();
    final to = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: BodhiColors.paperLight,
        title: Text('邮件接口测试', style: BodhiTypography.pageTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '通过 APP 内置 SMTP 引擎（SSL 465）发送一封测试邮件，'
              '验证邮箱接口在本机是否可用。',
              style: BodhiTypography.caption,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                hintText: '收件邮箱',
                counterText: '',
              ),
              maxLength: 64,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text(
              '发送测试邮件',
              style: TextStyle(color: BodhiColors.gold),
            ),
          ),
        ],
      ),
    );
    controller.dispose();
    if (to == null || to.isEmpty || !mounted) return;

    _showLoading('正在通过 SMTP 发送测试邮件…');
    String message;
    try {
      await EmailBridge.instance.send(
        to: to,
        subject: '【菩提护令】APP 邮件接口测试',
        body: '这是一封来自菩提护令 APP 的测试邮件。\n\n'
            '如果您收到了它，说明 APP 内置 SMTP 邮件接口在本机工作正常。\n\n'
            '发送时间：${DateTime.now().toString().substring(0, 19)}\n'
            '—— 菩提护令超级管理员后台',
      );
      message = '测试邮件已发送到 $to，请查收确认。';
    } on EmailException catch (e) {
      message = '发送失败：${e.message}';
    } catch (_) {
      message = '发送失败：网络异常，请稍后重试';
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    // 审计上报（尽力而为）
    try {
      await _api.adminAudit(token, '邮件接口测试 -> $to : $message');
    } catch (_) {}

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: BodhiColors.paperLight,
        title: Text(
          message.startsWith('发送失败') ? '测试失败' : '测试完成',
          style: BodhiTypography.pageTitle,
        ),
        content: Text(message, style: BodhiTypography.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('我知道了'),
          ),
        ],
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
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showLoading(String text) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: BodhiColors.cardWhite,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor: AlwaysStoppedAnimation(BodhiColors.gold),
                ),
                const SizedBox(height: 16),
                Text(text, style: BodhiTypography.caption),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _logout() async {
    await AdminBridge.instance.logout();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: BodhiColors.pageGradient),
      child: SafeArea(
        child: Column(
          children: [
            BodhiNavBar(
              title: '后台管理',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: Column(
                children: [
                  _buildHeader(),
                  _buildTabs(),
                  Expanded(
                    child: TabBarView(
                      controller: _tab,
                      children: [
                        _buildUserTab(),
                        _buildLogTab(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Container(
        padding: const EdgeInsets.all(16),
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
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.admin_panel_settings_outlined,
                        size: 18,
                        color: BodhiColors.gold,
                      ),
                      const SizedBox(width: 6),
                      Text('超级管理员', style: BodhiTypography.groupTitle),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '注册用户总数：$_total 人',
                    style: BodhiTypography.caption.copyWith(
                      color: BodhiColors.inkGray,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '邮件接口测试',
              onPressed: _smtpTest,
              icon: const Icon(
                Icons.mark_email_unread_outlined,
                size: 20,
                color: BodhiColors.gold,
              ),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: _loading ? null : _refresh,
              icon: const Icon(
                Icons.refresh,
                size: 20,
                color: BodhiColors.gold,
              ),
            ),
            IconButton(
              tooltip: '退出管理',
              onPressed: _logout,
              icon: const Icon(
                Icons.logout,
                size: 20,
                color: BodhiColors.cinnabar,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Container(
        decoration: BoxDecoration(
          color: BodhiColors.cardWhite,
          borderRadius: BorderRadius.circular(16),
        ),
        child: TabBar(
          controller: _tab,
          indicatorSize: TabBarIndicatorSize.tab,
          indicatorColor: BodhiColors.gold,
          labelColor: BodhiColors.gold,
          unselectedLabelColor: BodhiColors.inkGray,
          dividerColor: Colors.transparent,
          tabs: const [
            Tab(height: 40, text: '注册用户'),
            Tab(height: 40, text: '日志 / 审计'),
          ],
        ),
      ),
    );
  }

  // ── Tab 1 · 注册用户 ───────────────────────────────────

  Widget _buildUserTab() {
    if (_loading && _users.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(BodhiColors.gold),
          ),
        ),
      );
    }
    if (_error != null) {
      return _buildErrorView(_error!, _refresh);
    }
    if (_users.isEmpty) {
      return Center(
        child: Text(
          '还没有注册用户',
          style: BodhiTypography.body.copyWith(color: BodhiColors.inkGray),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 200) {
          _loadMore();
        }
        return false;
      },
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        itemCount: _users.length + (_hasMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index >= _users.length) {
            return const Padding(
              padding: EdgeInsets.all(12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(BodhiColors.gold),
                  ),
                ),
              ),
            );
          }
          return _buildUserCard(_users[index]);
        },
      ),
    );
  }

  // ── Tab 2 · 日志 / 审计 ────────────────────────────────

  Widget _buildLogTab() {
    if (_logLoading && _logs.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(BodhiColors.gold),
          ),
        ),
      );
    }
    if (_logError != null) {
      return _buildErrorView(_logError!, _refreshLogs);
    }
    if (_logs.isEmpty) {
      return Center(
        child: Text(
          '暂无日志',
          style: BodhiTypography.body.copyWith(color: BodhiColors.inkGray),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 200) {
          _loadMoreLogs();
        }
        return false;
      },
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        itemCount: _logs.length + (_logHasMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index >= _logs.length) {
            return const Padding(
              padding: EdgeInsets.all(12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(BodhiColors.gold),
                  ),
                ),
              ),
            );
          }
          return _buildLogCard(_logs[index]);
        },
      ),
    );
  }

  Widget _buildLogCard(AdminLogItem log) {
    final isAudit = log.action.startsWith('管理') || log.action.startsWith('邮件');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: BodhiColors.cardWhite,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: (isAudit ? BodhiColors.gold : BodhiColors.moss)
                  .withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isAudit
                  ? Icons.history_edu_outlined
                  : Icons.login_outlined,
              size: 16,
              color: isAudit ? BodhiColors.gold : BodhiColors.moss,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${log.action} · ${log.account}',
                  style: BodhiTypography.rowLabel.copyWith(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${log.time} · IP ${log.ip}',
                  style: BodhiTypography.caption.copyWith(
                    fontSize: 11,
                    color: BodhiColors.inkFaint,
                  ),
                ),
              ],
            ),
          ),
          Text(
            log.result,
            style: BodhiTypography.caption.copyWith(
              fontSize: 11,
              color: log.result == '成功'
                  ? BodhiColors.moss
                  : BodhiColors.cinnabar,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView(String message, VoidCallback retry) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              size: 36,
              color: BodhiColors.inkFaint,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: BodhiTypography.body.copyWith(
                color: BodhiColors.inkGray,
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: retry,
              child: const Text(
                '重试',
                style: TextStyle(color: BodhiColors.gold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserCard(AdminUserItem u) {
    final masked = u.phone.length >= 7
        ? '${u.phone.substring(0, 3)}****${u.phone.substring(u.phone.length - 4)}'
        : u.phone;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: BodhiColors.cardWhite,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: BodhiColors.gold.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Text(
              u.nickname.isNotEmpty ? u.nickname.characters.first : '用',
              style: BodhiTypography.rowLabel.copyWith(
                color: BodhiColors.gold,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  u.nickname.isNotEmpty ? u.nickname : masked,
                  style: BodhiTypography.rowLabel,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  'ID ${u.id} · ${u.createdAt.isEmpty ? "时间未知" : u.createdAt}',
                  style: BodhiTypography.caption.copyWith(
                    fontSize: 11,
                    color: BodhiColors.inkFaint,
                  ),
                ),
              ],
            ),
          ),
          Text(
            u.status == 'active' ? '正常' : '已停用',
            style: BodhiTypography.caption.copyWith(
              color: u.status == 'active'
                  ? BodhiColors.moss
                  : BodhiColors.cinnabar,
            ),
          ),
        ],
      ),
    );
  }
}
