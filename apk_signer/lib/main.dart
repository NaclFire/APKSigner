import 'dart:io';

import 'package:apk_signer/models/keystore_profile.dart';
import 'package:apk_signer/models/sign_mode.dart';
import 'package:apk_signer/pages/home_page.dart';
import 'package:apk_signer/services/desktop_signer.dart';
import 'package:apk_signer/services/signer.dart';
import 'package:flutter/material.dart';

void main(List<String> args) async {
  // MethodChannel 依赖 ServicesBinding，先初始化（GUI 模式同样安全）。
  WidgetsFlutterBinding.ensureInitialized();

  // 命令行自检：apk_signer.exe --selftest
  if (args.contains('--selftest')) {
    exit(await _runSelftest());
  }
  // 命令行签名自测：apk_signer.exe --sign-test <input.apk> [v1|v1v2|v2only|v1v2v3]
  // 走与 GUI 完全相同的签名/校验链路（含 keytool 生成测试 keystore）。
  final i = args.indexOf('--sign-test');
  if (i >= 0 && i + 1 < args.length) {
    exit(
      await _runSignTest(
        args[i + 1],
        i + 2 < args.length ? args[i + 2] : 'v1v2',
      ),
    );
  }
  runApp(const ApkSignerApp());
}

/// 自检报告：内置 JRE / apksigner / keytool 是否可用。
Future<int> _runSelftest() async {
  final lines = <String>['== APK 签名工具自检 =='];
  var code = 0;
  try {
    final dir = await DesktopSigner.assetsDir();
    lines.add('资源目录: $dir');
    lines.add('目录存在: ${Directory(dir).existsSync()}');
    final signer = DesktopSigner(dir);
    lines.add(await signer.doctor());
  } catch (e) {
    lines.add('自检失败: $e');
    code = 1;
  }
  final report = lines.join('\n');
  print(report);
  // 同时写入 exe 旁 selftest.log，便于无控制台环境查看
  try {
    final exePath = Platform.resolvedExecutable;
    final dir = File(exePath).parent.path;
    File('$dir${Platform.pathSeparator}selftest.log').writeAsStringSync(report);
  } catch (_) {}
  return code;
}

/// 端到端签名自测：生成临时 keystore → 签名 → 校验，全程走桌面签名链路。
Future<int> _runSignTest(String inputApk, String modeArg) async {
  SignMode mode;
  switch (modeArg) {
    case 'v1':
      mode = SignMode.v1Only;
      break;
    case 'v2only':
      mode = SignMode.v2Only;
      break;
    case 'v1v2v3':
      mode = SignMode.v1V2V3;
      break;
    case 'v1v2':
    default:
      mode = SignMode.v1V2;
      break;
  }
  final lines = <String>['== APK 签名自测 ($modeArg) =='];
  var code = 0;
  try {
    final inPath = File(inputApk).absolute.path;
    if (!File(inPath).existsSync()) throw SignerException('输入不存在: $inPath');
    final signer = DesktopSigner(await DesktopSigner.assetsDir());

    // 临时工作目录：测试 keystore + 输出 APK
    final workDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}apk_signer_selftest',
    )..createSync(recursive: true);
    final ksPath = '${workDir.path}${Platform.pathSeparator}test_signer.p12';
    final profile = KeystoreProfile(
      id: 'selftest',
      name: 'selftest',
      keystorePath: ksPath,
      storePassword: 'selftest123',
      keyPassword: 'selftest123',
      alias: 'selftest',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (!File(ksPath).existsSync()) {
      lines.add('生成测试 keystore ...');
      final kr = await signer.createKeystore(
        path: ksPath,
        alias: 'selftest',
        dn: 'CN=APK Signer Selftest, O=Fire, C=CN',
        storePass: 'selftest123',
        keyPass: 'selftest123',
        validityDays: 365,
      );
      if (!kr.success) throw SignerException('keystore 生成失败: ${kr.message}');
    } else {
      lines.add('复用已有测试 keystore: $ksPath');
    }

    // 与 UI 相同的输出命名：<name>_sign.apk
    final base = inPath.replaceAll(RegExp(r'\.[^.]+$'), '');
    final outPath = '${base}_sign.apk';
    lines.add('输入: $inPath');
    lines.add('输出: $outPath');
    final sr = await signer.sign(
      inputApk: inPath,
      outputApk: outPath,
      profile: profile,
      mode: mode,
      onLog: (l) => lines.add('  [log] $l'),
    );
    lines.add('签名: ${sr.success ? "OK" : "失败 - ${sr.message}"}');
    if (!sr.success) return 1;

    final vr = await signer.verify(
      outPath,
      onLog: (l) => lines.add('  [log] $l'),
    );
    lines.add(
      '校验: ok=${vr.ok} v1=${vr.v1} v2=${vr.v2} v3=${vr.v3} v3.1=${vr.v31} v3.2=${vr.v32}',
    );
    lines.add('证书 DN: ${vr.certDn ?? "?"}');
    lines.add('SHA-256: ${vr.certSha256 ?? "?"}');
    if (!vr.ok) code = 1;
  } catch (e) {
    lines.add('自测失败: $e');
    code = 1;
  }
  final report = lines.join('\n');
  print(report);
  try {
    final exePath = Platform.resolvedExecutable;
    final dir = File(exePath).parent.path;
    File('$dir${Platform.pathSeparator}signtest.log').writeAsStringSync(report);
  } catch (_) {}
  return code;
}

class ApkSignerApp extends StatelessWidget {
  const ApkSignerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'APK签名工具',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2962FF),
        // FilledButton 与 TextButton 的默认字重不一致（观感一粗一细）。
        // 显式指定 Windows 中文界面字体，避免中文字符在系统字体回退时
        // 被拆到不同字形中（例如「签」字看起来比同按钮中的其他字更细）。
        // 微软雅黑只有 Regular(400)/Bold(700) 两档，w500 会统一落到 Regular。
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            textStyle: const TextStyle(
              fontFamily: 'Microsoft YaHei UI',
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            textStyle: const TextStyle(
              fontFamily: 'Microsoft YaHei UI',
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2962FF),
        brightness: Brightness.dark,
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            textStyle: const TextStyle(
              fontFamily: 'Microsoft YaHei UI',
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            textStyle: const TextStyle(
              fontFamily: 'Microsoft YaHei UI',
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}
