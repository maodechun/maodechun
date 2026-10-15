# 菩提护令 · 源码工程说明

> Flutter 跨端工程，一套代码同时产出 **Android APK/AAB** 与 **iOS IPA**。
> 版本 v2.0.3　|　版权：道拓日记版权所有

---

## 一、这个工程能产出什么

| 平台 | 产物 | 说明 |
|---|---|---|
| Android | `app-release.apk` / `app-release.aab` | 可直接分发安装 / 提交商店 |
| iOS | `bodhi_token.ipa` | 需 macOS + Xcode 编译，提交 App Store |

**注意：** 编译必须在本机安装开发环境后执行。本目录只包含源码，不含预编译产物。

---

## 二、环境准备

### 2.1 通用

```bash
# 1. 安装 Flutter SDK（3.16 及以上）
#    https://docs.flutter.dev/get-started/install

# 2. 验证环境
flutter doctor

# 3. 进入工程目录
cd bodhi_token

# 4. 拉取依赖
flutter pub get
```

### 2.2 Android 额外需要

- JDK 17
- Android Studio（含 Android SDK，API 34）
- 接受许可：`flutter doctor --android-licenses`

### 2.3 iOS 额外需要

- macOS 系统
- Xcode 15 及以上
- CocoaPods：`sudo gem install cocoapods`
- Apple 开发者账号（付费 $99/年）

---

## 三、打包命令

### 3.1 Android

```bash
# 清理
flutter clean && flutter pub get

# 方式一：直接生成 APK（通用包，可直接安装）
flutter build apk --release

# 产物：build/app/outputs/flutter-apk/app-release.apk

# 方式二：生成 AAB（推荐用于商店提交，体积更小）
flutter build appbundle --release

# 产物：build/app/outputs/bundle/release/app-release.aab
```

**首次打包会失败**，因为未配置签名。请先按第四节生成签名证书。

### 3.2 iOS

```bash
cd ios && pod install && cd ..

flutter build ipa --release

# 产物：build/ios/ipa/bodhi_token.ipa

# 或使用 Xcode：Product → Archive → Distribute App
```

---

## 四、Android 签名证书配置（必做）

### 4.1 生成证书（仅一次，务必备份！）

```bash
keytool -genkeypair -v \
  -keystore bodhi_token.jks \
  -alias bodhi \
  -keyalg RSA -keysize 2048 -validity 36500 \
  -storepass 你的密码 -keypass 你的密码 \
  -dname "CN=道拓日记, OU=Dev, O=Daotuo Diary, L=Chengdu, ST=Sichuan, C=CN"
```

⚠️ **`.jks` 文件与密码丢失后，已上架的应用将永远无法更新。请立即备份到安全位置。**

### 4.2 配置签名文件

在 `android/` 目录下创建 `key.properties`：

```properties
storePassword=你的密码
keyPassword=你的密码
keyAlias=bodhi
storeFile=../keys/bodhi_token.jks
```

### 4.3 在 build.gradle 中引用

在 `android/app/build.gradle` 的 `android { }` 块**之前**添加：

```gradle
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}
```

在 `android { }` 块**内**添加：

```gradle
signingConfigs {
    release {
        keyAlias keystoreProperties['keyAlias']
        keyPassword keystoreProperties['keyPassword']
        storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
        storePassword keystoreProperties['storePassword']
    }
}
buildTypes {
    release {
        signingConfig signingConfigs.release
        minifyEnabled true
        shrinkResources true
    }
}
```

### 4.4 验证签名

```bash
keytool -list -v -keystore bodhi_token.jks -alias bodhi
```

输出的 MD5 / SHA1 / SHA256 需填入应用商店后台。

---

## 五、需要手动放置的资源文件

工程引用了以下资源，需自行准备后放入对应目录：

| 文件 | 位置 | 说明 |
|---|---|---|
| `splash_buddha.png` | `assets/images/` | 佛祖启动页插画（已生成，见 `../generated-images/`） |
| `namo_amitabha.mp3` | `assets/audio/` | 开屏语音「南无阿弥陀佛」，约 2.4 秒 |
| `SourceHanSerifSC-*.otf` | `assets/fonts/` | 思源宋体，若不想打包可在 `theme/typography.dart` 中改用系统字体 |

**字体获取：** https://github.com/adobe-fonts/source-han-serif/releases

---

## 六、代码结构

```
lib/
├─ main.dart                    # 应用入口，路由与全局状态
├─ theme/
│  ├─ colors.dart               # 宣纸米黄 + 鎏金色板
│  └─ typography.dart           # 宋体 / Inter / 等宽字体规范
├─ core/
│  ├─ totp/
│  │  ├─ generator.dart         # TOTP 算法（HMAC-SHA1，RFC 6238）
│  │  └─ uri_parser.dart        # otpauth:// URI 解析
│  ├─ security/
│  │  ├─ secret_store.dart      # 密钥加密存储（Keystore / Keychain）
│  │  └─ clipboard_guard.dart   # 剪贴板敏感标记 + 30 秒自动清空
│  └─ time/
│     └─ ntp_client.dart        # NTP 校时，处理时钟漂移
├─ data/
│  ├─ models/token.dart         # 令牌数据模型
│  ├─ repository/token_repository.dart  # 令牌增删改查（加密落盘）
│  └─ services/
│     ├─ ftp_backup_service.dart    # FTP 加密备份 / 恢复
│     └─ update_service.dart        # app.0499.com.cn 版本检测
├─ widgets/                     # 金莲徽记、倒计时环、鎏金按钮等
└─ features/
   ├─ splash/                   # S0 启动页（逐字动效 + 语音 + 早课晚课）
   ├─ lock/                     # S1 锁屏 + S3 解锁（密码/指纹/人脸）
   ├─ scan/                     # S2 扫码绑定（含权限流程与闪退防护）
   ├─ token_list/               # S4 令牌列表
   ├─ settings/                 # S5 设置（FTP 备份 / 更新 / 关于）
   ├─ export/                   # S6 导出密钥（二维码 + 文本）
   ├─ browser/                  # 内置浏览器 m.0499.com.cn
   └─ legal/                    # 隐私政策页（首次启动拦截）
```

---

## 七、已实现的关键能力

### 安全

- ✅ TOTP 标准算法（HMAC-SHA1 / 30 秒 / 6 位），与 Google Authenticator 兼容
- ✅ 密钥经 Android Keystore / iOS Keychain 硬件级加密后落盘，明文不出现于任何文件
- ✅ 倒计时环剩余 ≤5 秒自动变朱砂色提醒
- ✅ 剪贴板复制密钥后 30 秒自动清空，并标记为敏感内容
- ✅ 连续密码错误 5 次锁定 30 秒，10 次锁定 5 分钟

### 扫码（闪退修复已落地）

- ✅ 进页前检查权限状态，未授权先展示用途说明弹窗
- ✅ 相机初始化全流程 try-catch，失败降级为手动输入，**不会崩溃**
- ✅ 权限被拒后展示引导页（前往系统设置 / 手动输入）
- ✅ 生命周期结束时正确释放相机资源

### 其他

- ✅ 开屏逐字淡入动效（月轮 0→600ms，四字 300ms 起每字错开 120ms）
- ✅ 早课 / 晚课问候语按时间自动切换（05:00–17:59 / 18:00–04:59）
- ✅ 开屏语音「南无阿弥陀佛」，可在设置中关闭
- ✅ FTP 加密备份与恢复（FTPS 优先，失败降级 FTP 并提示风险）
- ✅ 在线更新检测（app.0499.com.cn），强制更新弹窗不可绕过
- ✅ 邮箱点击唤起系统邮件客户端，电话点击唤起拨号盘
- ✅ 内置浏览器打开 m.0499.com.cn（仅允许 https）
- ✅ 首次启动隐私政策拦截，未同意不可进入
- ✅ 底部安全区适配（三键导航 / 手势导航 / 全面屏）

---

## 八、注意事项

1. **TOTP 核心不可依赖网络。** 飞行模式下除 FTP 备份与更新检测外，全部功能必须可用。
2. **不要在调试构建中打印密钥。** 上线前请全局搜索确认无 `print(secret)` 类代码。
3. **iOS 不支持应用内自更新。** 检测到新版本仅提示前往 App Store。
4. **位置权限需说明用途。** 仅用于局域网 FTP 服务器发现，审核时会被追问。
5. **ProGuard 需保留加密相关类。** 已在 `android/app/proguard-rules.pro` 中给出规则。

---

## 九、最小可跑通验证

打包成功后，按以下顺序自测：

1. 安装 → 首次启动出现隐私政策页 → 不同意则无法进入 ✅
2. 同意 → 启动页佛祖图 + 「阿弥陀佛」逐字淡入 + 佛号语音 ✅
3. 进入令牌列表（空态）→ 点右下角 → 扫码页不闪退 ✅
4. 拒绝相机权限 → 展示引导页，可手动输入密钥 ✅
5. 输入 `JBSWY3DPEHPK3PXP` → 列表出现 30 秒滚动验证码 ✅
6. 与 Google Authenticator 同密钥比对，结果一致 ✅
7. 设置 → 关闭开屏语音 → 重启后不再播放 ✅
8. 设置 → 邮箱 → 唤起邮件客户端 ✅
9. 设置 → 打开官网 → 内置浏览器加载正确 ✅
10. 三键导航 / 手势导航切换，底部无遮挡 ✅

---

*文档结束 · 道拓日记版权所有*
