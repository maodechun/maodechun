import 'package:flutter/material.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/common.dart';
import 'account_api.dart';
import 'admin_bridge.dart';

/// 超级管理员 · 后台管理页
///
/// 进入本页前必须先通过本地管理员校验（关于页底部入口）。
/// 页面内所有数据均来自服务端管理接口，需携带管理员会话令牌。
class AdminPage extends StatefulWidget {
  const AdminPage({super.key});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  final AccountApi _api = AccountApi.instance;

  bool _loading = true;
  String? _error;
  int _total = 0;
  int _page = 1;
  bool _hasMore = false;
  final List<AdminUserItem> _users = [];
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _searchController.dispose();
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
                  Expanded(child: _buildBody()),
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

  Widget _buildBody() {
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
                _error!,
                textAlign: TextAlign.center,
                style: BodhiTypography.body.copyWith(
                  color: BodhiColors.inkGray,
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _refresh,
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
