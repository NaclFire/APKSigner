# APK签名工具 (apk_signer)

跨平台 APK 签名工具，一个 Flutter 代码库同时覆盖 **Windows / macOS / Android**。

- 选择 APK，用保存在**应用私有数据目录**里的 keystore 签名（之后可直接选用，无需再回设备里找文件）
- 支持 4 种签名模式：
  | 模式 | 实际签名方案 |
  |---|---|
  | V1 | v1 (JAR) 仅 |
  | V2 | v1 + v2 |
  | V2 Only | v2 仅 |
  | V3 | v1 + v2 + v3 |
- 签名产物自动命名 `<原名>_sign.apk`，签名完成后自动用 apksig 回读校验各方案
- 内置 keystore 生成器（自签名证书，PKCS12），密码与别名随档案一起保存

## 目录结构

```
apk_signer/
├── lib/
│   ├── main.dart                  # 入口 + CLI 诊断（--selftest / --sign-test）
│   ├── pages/home_page.dart       # 主界面
│   ├── models/                    # KeystoreProfile / SignMode
│   └── services/
│       ├── signer.dart            # 签名服务抽象接口
│       ├── desktop_signer.dart    # 桌面端：内置 JRE + apksigner.jar（子进程）
│       ├── android_signer.dart    # Android：MethodChannel → Kotlin apksig
│       └── keystore_store.dart    # keystore 档案持久化
├── assets/signer/                 # Windows 签名运行时（内置精简 JRE + apksigner.jar）
├── assets/signer-macos/           # macOS 签名运行时（首次构建由脚本生成）
├── scripts/make-macos-jre.sh      # 生成 macOS 版 JRE（Temurin + jlink）
├── windows/runner/                # C++ 通道实现（desktop_channel.cpp）
├── macos/Runner/                  # Swift 通道实现
└── android/app/src/main/kotlin/fire/apk_signer/   # Kotlin 通道实现
```

## 构建

> **中文路径问题**：本项目目录名含中文（`E:\apk签名工具`），会破坏 MSBuild/CMake。
> 已建 NTFS junction `E:\apsig` → `E:\apk签名工具\apk_signer`，**所有构建命令都在 `E:\apsig` 下执行**。

> **网络代理**：本机 JVM 出网必须走本地代理 `127.0.0.1:10808`（WinINET 代理）。
> .NET/PowerShell 自动使用；JVM 需要显式参数。Gradle daemon 的代理已写死在
> `android/gradle.properties` 的 `org.gradle.jvmargs` 里；命令行另起的 JVM
> 需要先设环境变量：
> ```powershell
> $env:JAVA_TOOL_OPTIONS='-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=10808 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=10808'
> ```

### Windows

```powershell
cd E:\apsig
flutter build windows --release
```

- 签名运行时 `assets/signer/`（内置精简 JRE + apksigner.jar + keytool）由 CMake
  POST_BUILD 步骤复制到输出目录 `build\windows\x64\runner\Release\signer\`
- JRE 由 JDK 17 `jlink` 定制生成；`keytool.exe` 从 JDK bin 手工拷入（jlink 不带它）
- 产物：`build\windows\x64\runner\Release\apk_signer.exe`（连同 signer\ 一起分发）

### macOS（需在 macOS 机器上执行）

```bash
cd <仓库>/apk_signer
flutter build macos --release
```

> 已在 Xcode 16.4 + Flutter 3.47.7（Dart 3.13.5）上验证。macOS 端不启用
> App Sandbox（`Release.entitlements` / `DebugProfile.entitlements` 均无
> `app-sandbox`）：工具需要读取用户选择的任意 APK、在源文件旁写出
> `<原名>_sign.apk`，并启动内置 JRE，沙箱会拦截这些操作。

- 首次构建时 Xcode 工程里的 "Copy Signer Runtime" Run Script 会自动执行
  `scripts/make-macos-jre.sh`：下载当前架构的 Temurin JDK 17、用与 Windows 端
  完全相同的模块集做 jlink、拷入 keytool 与 apksigner.jar，生成
  `assets/signer-macos/jre`，然后复制到 `Contents/Resources/signer/`
- 签名运行时不在 Flutter assets 里（Flutter 资产管线会丢弃 .exe/.dll/.jnilib 等
  扩展名，且会撑爆 Android APK），全部走原生拷贝通道

### macOS 安装包（DMG）

```bash
cd <仓库>/apk_signer
./scripts/make-macos-dmg.sh
```

- 内部执行 `flutter build macos --release`，再对内置 JRE 的 Mach-O 二进制与
  app 做 ad-hoc 签名（可用 `CODESIGN_IDENTITY` 指定开发者证书），最后用
  `hdiutil` 打包成带 Applications 快捷方式的 DMG
- DMG 窗口布局与 electron-builder 默认样式一致（540×380、图标定位、拖入
  Applications）；优先用 `dmgbuild`（不依赖 Finder 授权），没有时退回
  Finder + AppleScript，均不可用时生成普通 DMG，也可用 `DMG_LAYOUT=0` 跳过
- 可选安装 `dmgbuild` 获得稳定布局：`python3 -m venv ~/.local/share/apk-signer/dmgvenv && ~/.local/share/apk-signer/dmgvenv/bin/pip install dmgbuild`
  （脚本会自动识别该路径，也支持 `DMGBUILD=/path/to/dmgbuild`）
- 产物按 NexSSH-PC 的方式命名：`dist/APK签名工具-<版本>.dmg`（x64）、
  `dist/APK签名工具-<版本>-arm64.dmg`（arm64）
- 复用已有构建、只重新打包：`SKIP_BUILD=1 ./scripts/make-macos-dmg.sh`
- 注意：未使用 Developer ID 证书 + 公证时，其他 Mac 首次打开需右键「打开」，
  或执行 `xattr -dr com.apple.quarantine /Applications/APK签名工具.app`

### Android

```powershell
cd E:\apsig
$env:JAVA_TOOL_OPTIONS='-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=10808 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=10808'
flutter build apk --debug
```

- 签名直接用 **apksig 库**（`com.android.tools.build:apksig:8.7.3`，即
  apksigner.jar 的底层库）+ BouncyCastle（`bcpkix/bcprov-jdk15to18:1.78.1`）
  在 Kotlin 侧完成，无需打包 JRE
- MethodChannel：`apk_signer/android`
- 注意：apksig 8.7.3 的 API 与 build-tools 37.0.0 的 jar 不同——`ApkSigner.sign()`
  无参（输入输出通过 Builder 的 setInputApk/setOutputApk 设置），且没有 V3.2 验签
- Android 的 `java.security.KeyStore` stub 用 `aliases()` 方法而非 JDK 的
  `getAliases()`，Kotlin 侧要按 Android 的签名写

## keystore 档案存放位置

`<应用支持目录>/keystores/`：

- `profiles.json` — 档案索引（名称、别名、密码等）
- 各 `.keystore` / `.p12` 文件本体（密码与别名随档案保存）

Windows 下应用支持目录为 `%APPDATA%\<包名>`。

## 命令行诊断（仅桌面端）

```powershell
# 自检：内置 JRE / apksigner / keytool 是否可用（报告同时写 selftest.log）
.\apk_signer.exe --selftest

# 端到端签名自测：生成临时 keystore → 签名 → 校验（报告同时写 signtest.log）
.\apk_signer.exe --sign-test <input.apk> [v1|v1v2|v2only|v1v2v3]   # 默认 v1v2
```

`--selftest` 会在 main.cpp 里 `AllocConsole()` 挂控制台输出；两种模式都把报告
写到 exe 同目录的 `selftest.log` / `signtest.log`，方便无控制台环境查看。

## 已知环境特性

- **CreateProcess 环境块在本机不可用**：任何非 NULL 的 lpEnvironment 都返回
  错误 87（疑似 EDR 钩子，连手工构造的 `OS=Windows_NT\0\0` 都会被拒）。
  桌面端隐藏子进程改为 `SetEnvironmentVariableW` 覆写 → `lpEnvironment=NULL`
  继承 → 事后恢复。
- **C4819**：无 BOM 的 UTF-8 C++ 文件若中文注释的乱码字节以 `\` 结尾会静默吞掉
  下一行。临时测试用 C++ harness 保持纯 ASCII。
- `dart analyze` 可用；LSP 的 `flutter analyze` 在本环境会崩。
