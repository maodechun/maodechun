import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 背景音乐服务：《云水禅心》古筝曲循环播放
///
/// - 进入主界面后自动开始播放（首次解锁 / 无锁直接进入均覆盖）
/// - 全程循环（ReleaseMode.loop）
/// - 底部导航栏右侧提供暂停 / 播放按钮，用户自主控制
/// - 开关状态持久化（SharedPreferences，key: music_enabled），默认开启
/// - 退到后台自动暂停，回前台若处于主界面则恢复
/// - 全部操作包 try-catch：音频缺失 / 播放失败绝不影响 app 主流程
class BackgroundMusic extends ChangeNotifier {
  BackgroundMusic._();

  static final BackgroundMusic instance = BackgroundMusic._();

  static const String _asset = 'audio/yunshui_chanxin.mp3';
  static const String _prefKey = 'music_enabled';

  AudioPlayer? _player;
  bool _enabled = true;
  bool _inited = false;

  /// 当前是否应处于播放状态（用户开关）
  bool get enabled => _enabled;

  Future<void> _init() async {
    if (_inited) return;
    _inited = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? true;
    } catch (_) {
      _enabled = true;
    }
    try {
      final player = AudioPlayer();
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(0.6);
      await player.setSource(AssetSource(_asset));
      _player = player;
    } catch (_) {
      _player = null;
    }
  }

  /// 进入主界面时调用：初始化并按用户开关开始循环播放
  Future<void> ensureStarted() async {
    await _init();
    if (_enabled) {
      await _resume();
    }
  }

  /// 用户点击底部按钮切换开关
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (_) {}
    if (value) {
      await _resume();
    } else {
      await _pause();
    }
  }

  /// 退到后台：暂停（若在播放）
  Future<void> pauseForBackground() async {
    if (_enabled) await _pause();
  }

  /// 回到前台且处于主界面：恢复播放（若开关开启）
  Future<void> resumeIfEnabled() async {
    if (_enabled) await _resume();
  }

  Future<void> _resume() async {
    try {
      await _player?.resume();
    } catch (_) {}
  }

  Future<void> _pause() async {
    try {
      await _player?.pause();
    } catch (_) {}
  }
}
