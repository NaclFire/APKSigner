import 'dart:io';

import 'package:apk_signer/models/keystore_profile.dart';
import 'package:apk_signer/models/sign_mode.dart';
import 'package:apk_signer/services/signer.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// 桌面端（Windows / macOS）签名实现：
/// 调用打包在应用旁的 signer 目录里的精简 JRE + apksigner.jar / keytool。
///
/// 布局：<app_dir>/signer/{apksigner.jar, jre/bin/...}，由各平台的原生构建
/// （Windows CMake POST_BUILD / macOS Xcode Run Script）整体拷贝而来，
/// 因为 pubspec 资产管道会丢弃 .exe/.dll。
///
/// Windows 上通过原生 `runHidden` 启动进程（CREATE_NO_WINDOW），避免弹出黑色控制台窗口；
/// macOS 直接用 dart:io Process。
class DesktopSigner implements Signer {
  static final _channel = MethodChannel('apk_signer/desktop');

  final String _assetsDir;
  late final String _java = _binPath('java');
  late final String _keytool = _binPath('keytool');
  late final String _apksignerJar = '$_assetsDir/apksigner.jar';

  DesktopSigner(this._assetsDir);

  String _binPath(String name) {
    final exe = Platform.isWindows ? '.exe' : '';
    return '$_assetsDir/jre/bin/$name$exe';
  }

  /// 解析打包进来的签名运行环境目录（signer）。
  static Future<String> assetsDir() async {
    final dir = await _channel.invokeMethod<String>('getAssetsDir');
    if (dir == null || dir.isEmpty) {
      throw SignerException('未找到打包资源目录（signer）');
    }
    return dir;
  }

  Future<_ProcResult> _runJava(List<String> args,
      {Map<String, String>? env, String? command}) async {
    final exe = command ?? _java;
    if (Platform.isWindows) {
      // Windows：子进程继承父进程环境，只需传"覆盖"变量（如 JAVA_TOOL_OPTIONS）。
      // 原生端会临时 SetEnvironmentVariableW 后启动、结束再还原，
      // 避免构造 CreateProcess 的 lpEnvironment 块（本机任何自定义块都报 87）。
      final payload = <String, Object>{'command': exe, 'args': args};
      if (env != null) payload['env'] = env;
      try {
        final r = await _channel.invokeMapMethod<String, Object>('runHidden', payload);
        return _ProcResult(
          (r?['exitCode'] as num?)?.toInt() ?? -1,
          r?['stdout'] as String? ?? '',
          r?['stderr'] as String? ?? '',
        );
      } on PlatformException catch (e) {
        throw SignerException(e.message ?? 'runHidden failed');
      }
    } else {
      final p = await Process.run(exe, args,
          environment: {...Platform.environment, ...?env});
      return _ProcResult(p.exitCode, p.stdout as String, p.stderr as String);
    }
  }

  /// 强制英文 locale 的环境变量（keytool 输出才可稳定解析）。
  static Map<String, String> _localeEnv() =>
      {'JAVA_TOOL_OPTIONS': '-Duser.language=en -Duser.country=US'};

  @override
  Future<SignResult> sign({
    required String inputApk,
    required String outputApk,
    required KeystoreProfile profile,
    required SignMode mode,
    void Function(String line)? onLog,
  }) async {
    final log = onLog ?? (_) {};
    final sw = Stopwatch()..start();
    log('签名输入：${p.basename(inputApk)}');
    log('签名方案：V1=${mode.v1} V2=${mode.v2} V3=${mode.v3}');
    log('签名文件：${p.basename(profile.keystorePath)}（别名 ${profile.alias}）');
    try {
      // 输出路径若已存在旧成品，必须先删掉：旧成品常是只读的
      // （如 360 加壳后保护），直接覆盖会抛 AccessDeniedException。
      // 被占用删不掉时给出明确提示。
      final out = File(outputApk);
      if (out.existsSync()) {
        log('检测到已存在的输出文件，先解除只读并删除…');
        try {
          await _clearReadOnly(outputApk);
          await out.delete();
          log('旧输出文件已删除');
        } on SignerException {
          rethrow;
        } catch (e) {
          throw SignerException(
              '无法删除已存在的输出文件（可能被其他程序占用）：\n$outputApk\n'
              '请关闭正在使用它的程序（资源管理器预览、加壳工具等）后重试。\n($e)');
        }
      }
      // 用 --in/--out 直接从输入签名写出输出，不再先复制大文件：
      // 同步的 File.copy 会在百 MB 级别的 APK 上阻塞 UI 线程数秒。
      // 输入只读也没关系，apksigner 只读它。
      log('启动 apksigner 签名（JVM 启动 + 签名约需数秒）…');
      final r = await _runJava([
        '-jar', _apksignerJar, 'sign',
        '--ks', profile.keystorePath,
        '--ks-pass', 'pass:${profile.storePassword}',
        '--ks-key-alias', profile.alias,
        '--key-pass', 'pass:${profile.keyPassword}',
        '--v1-signing-enabled', mode.v1 ? 'true' : 'false',
        '--v2-signing-enabled', mode.v2 ? 'true' : 'false',
        '--v3-signing-enabled', mode.v3 ? 'true' : 'false',
        '--in', inputApk,
        '--out', outputApk,
      ]);
      if (r.exitCode != 0) {
        log('apksigner 退出码 ${r.exitCode}（耗时 ${sw.elapsed.inSeconds}s）');
        final msg = _cleanError(r.stderr.isEmpty ? r.stdout : r.stderr);
        log('错误：$msg');
        return SignResult(false, msg);
      }
      log('签名完成，耗时 ${sw.elapsed.inSeconds}s');
      log('输出：$outputApk');
      return SignResult(true, 'OK');
    } catch (e) {
      if (e is SignerException) rethrow;
      log('签名异常：$e');
      return SignResult(false, '签名失败：$e');
    }
  }

  @override
  Future<VerifyResult> verify(String apkPath, {void Function(String line)? onLog}) async {
    final log = onLog ?? (_) {};
    try {
      // apksigner 8.x 成功时只输出"验证范围内最高 SDK 下生效的方案"的
      // "<scheme> Signer:" 证书段，所以每个方案必须在它独占的窗口里探测：
      //   v1   : 18-23（SHA-256 JAR 签名 API 18 起可用，9-17 会误报）
      //   v2   : 24-27（v3 从 28 开始）
      //   v3   : 28-32（v3.1 从 33 开始）
      //   v3.1 : 33-35（v3.2 从 36 开始）
      //   v3.2 : 36-37
      const windows = <List<Object>>[
        ['v1', 18, 23, 'V1 Signer:'],
        ['v2', 24, 27, 'V2 Signer:'],
        ['v3', 28, 32, 'V3.0 Signer:'],
        ['v31', 33, 35, 'V3.1 Signer:'],
        ['v32', 36, 37, 'V3.2 Signer:'],
      ];
      final flags = <String, bool>{
        'v1': false,
        'v2': false,
        'v3': false,
        'v31': false,
        'v32': false,
      };
      final raw = StringBuffer();
      String? certDn;
      String? certSha;
      log('开始校验签名：${p.basename(apkPath)}');
      for (final w in windows) {
        log('校验 ${_schemeLabel(w[0] as String)} 方案（SDK ${w[1]}-${w[2]}）…');
        final r = await _runJava([
          '-jar', _apksignerJar, 'verify', '--print-certs',
          '--min-sdk-version', '${w[1]}',
          '--max-sdk-version', '${w[2]}',
          apkPath,
        ]);
        final out = (r.stdout + '\n' + r.stderr).trim();
        raw.writeln('[${w[1]}-${w[2]}] ${out.isEmpty ? '(无输出)' : out}');
        if (out.contains(w[3] as String)) {
          flags[w[0] as String] = true;
          certDn ??= _certField(out, 'certificate DN');
          certSha ??= _certField(out, 'certificate SHA-256 digest');
          log('  ✓ 发现 ${_schemeLabel(w[0] as String)} 签名');
        } else {
          log('  — 无 ${_schemeLabel(w[0] as String)} 签名');
        }
      }
      final ok = flags.values.any((b) => b);
      log(ok ? '校验完成：签名有效' : '校验完成：未发现有效签名');
      return VerifyResult(
        ok: ok,
        v1: flags['v1']!,
        v2: flags['v2']!,
        v3: flags['v3']!,
        v31: flags['v31']!,
        v32: flags['v32']!,
        certDn: certDn,
        certSha256: certSha,
        raw: raw.toString(),
      );
    } catch (e) {
      return VerifyResult(
          ok: false,
          v1: false,
          v2: false,
          v3: false,
          v31: false,
          v32: false,
          raw: '校验失败：$e');
    }
  }

  /// 校验日志用的方案名。
  static String _schemeLabel(String key) {
    const names = {'v1': 'V1', 'v2': 'V2', 'v3': 'V3.0', 'v31': 'V3.1', 'v32': 'V3.2'};
    return names[key] ?? key;
  }

  /// 提取 "<label>: <value>" 形式的证书字段。
  String? _certField(String out, String label) =>
      RegExp('$label:\\s*(.+)').firstMatch(out)?.group(1)?.trim();

  @override
  Future<SignResult> createKeystore({
    required String path,
    required String alias,
    required String dn,
    required String storePass,
    required String keyPass,
    required int validityDays,
  }) async {
    try {
      if (File(path).existsSync()) {
        return SignResult(false, '目标文件已存在：$path');
      }
      final r = await _runJava([
        '-genkeypair',
        '-alias', alias,
        '-keyalg', 'RSA',
        '-keysize', '2048',
        '-validity', '$validityDays',
        '-keystore', path,
        '-storetype', 'PKCS12',
        '-storepass', storePass,
        '-keypass', keyPass,
        '-dname', dn,
      ], command: _keytool, env: _localeEnv());
      if (r.exitCode != 0) {
        return SignResult(false, _cleanError(r.stderr.isEmpty ? r.stdout : r.stderr));
      }
      return SignResult(true, 'OK');
    } catch (e) {
      if (e is SignerException) rethrow;
      return SignResult(false, '生成失败：$e');
    }
  }

  @override
  Future<List<KeystoreAliasInfo>> listAliases({
    required String path,
    required String storePass,
  }) async {
    try {
      final r = await _runJava([
        '-list', '-v',
        '-keystore', path,
        '-storepass', storePass,
      ], command: _keytool, env: _localeEnv());
      if (r.exitCode != 0) {
        throw SignerException(
            _cleanError(r.stderr.isEmpty ? r.stdout : r.stderr));
      }
      return _parseKeytoolList(r.stdout);
    } on SignerException {
      rethrow;
    } catch (e) {
      throw SignerException('读取 keystore 失败：$e');
    }
  }

  /// 解析 keytool -list -v 输出（英文 locale）。
  List<KeystoreAliasInfo> _parseKeytoolList(String out) {
    final result = <KeystoreAliasInfo>[];
    String? alias;
    String? subject;
    String? type;
    DateTime? from;
    DateTime? to;

    void flush() {
      if (alias != null) {
        result.add(KeystoreAliasInfo(
          alias: alias!,
          subject: subject ?? '',
          type: type ?? '',
          validFrom: from,
          validTo: to,
        ));
      }
      alias = null;
      subject = null;
      type = null;
      from = null;
      to = null;
    }

    for (final raw in out.split('\n')) {
      final line = raw.trim();
      final mAlias = RegExp(r'^Alias name: (.+)$').firstMatch(line);
      if (mAlias != null) {
        flush();
        alias = mAlias.group(1)!;
        continue;
      }
      final mType = RegExp(r'^Entry type: (.+)$').firstMatch(line);
      if (mType != null) {
        type = mType.group(1)!;
        continue;
      }
      final mOwner = RegExp(r'^Owner:\s*(.+)$').firstMatch(line);
      if (mOwner != null) {
        subject = mOwner.group(1);
      }
      final mFrom = RegExp(r'^Not Before:\s*(.+)$').firstMatch(line);
      if (mFrom != null) from = _parseJavaDate(mFrom.group(1)!);
      final mTo = RegExp(r'^Not After:\s*(.+)$').firstMatch(line);
      if (mTo != null) to = _parseJavaDate(mTo.group(1)!);
    }
    flush();
    return result;
  }

  DateTime? _parseJavaDate(String s) {
    // e.g. "Mon Oct 21 12:00:00 CST 2026"
    const months = {
      'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
      'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
    };
    final m = RegExp(
        r'^(?:\w{3})\s+(\w{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+\w+\s+(\d{4})$')
        .firstMatch(s.trim());
    if (m == null) return null;
    final month = months[m.group(1)];
    if (month == null) return null;
    return DateTime(
        int.parse(m.group(6)!),
        month,
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!),
        int.parse(m.group(5)!));
  }

  @override
  Future<String> prepareInputPath(String pathOrUri) async => pathOrUri;

  /// 桌面端签名结果已经写在源 APK 同目录，无需再发布。
  @override
  Future<String> publishSignedApk({
    required String signedApk,
    String? sourceUri,
    required String fileName,
  }) async =>
      signedApk;

  /// 自检：检查内置 JRE / apksigner / keytool 是否可用，返回诊断报告。
  Future<String> doctor() async {
    final lines = <String>[
      'java:    $_java ${File(_java).existsSync() ? "OK" : "缺失!"}',
      'keytool: $_keytool ${File(_keytool).existsSync() ? "OK" : "缺失!"}',
      'apksigner: $_apksignerJar ${File(_apksignerJar).existsSync() ? "OK" : "缺失!"}',
    ];
    final jv = await _runJava(['-version']);
    lines.add('java -version 退出码 ${jv.exitCode}：${(jv.stderr.isEmpty ? jv.stdout : jv.stderr).split("\n").first}');
    final av = await _runJava(['-jar', _apksignerJar, 'version']);
    lines.add('apksigner 版本：${av.stdout.trim()}'
        '${av.exitCode == 0 ? '' : ' (退出码 ${av.exitCode}) ${av.stderr.split("\n").first}'}');
    return lines.join('\n');
  }

  /// 解除文件只读属性（幂等：本就可写则什么都不做）。
  Future<void> _clearReadOnly(String path) async {
    final st = File(path).statSync();
    // 属主写位缺失即只读（Windows 只读文件 mode 为 0444，Unix 同理）
    if ((st.mode & 0x2) != 0) return;
    final r = Platform.isWindows
        ? await Process.run('attrib', ['-R', path])
        : await Process.run('chmod', ['u+w', path]);
    if (r.exitCode != 0) {
      throw SignerException('解除只读属性失败：${r.stderr}');
    }
  }

  /// 去掉 java 异常栈噪音，只留第一行有效信息。
  String _cleanError(String s) {
    final lines = s
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return '未知错误';
    final first = lines.firstWhere((l) => !l.startsWith('at '),
        orElse: () => lines.first);
    // Windows 访问被拒（文件被占用 / 只读）→ 中文提示，附文件路径
    final m = RegExp(r'AccessDeniedException:\s*(\S+)').firstMatch(first);
    if (m != null) {
      return '输出文件没有写入权限（可能被占用或设为只读）：${m.group(1)}\n'
          '请关闭正在使用该文件的程序后重试。';
    }
    return first.length > 500 ? first.substring(0, 500) : first;
  }
}

class _ProcResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  _ProcResult(this.exitCode, this.stdout, this.stderr);
}
