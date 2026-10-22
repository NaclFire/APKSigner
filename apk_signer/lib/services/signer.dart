import 'dart:io';

import 'package:apk_signer/models/keystore_profile.dart';
import 'package:apk_signer/models/sign_mode.dart';
import 'package:apk_signer/services/desktop_signer.dart';
import 'package:apk_signer/services/android_signer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 签名操作结果。
class SignResult {
  final bool success;
  final String message;
  const SignResult(this.success, this.message);
}

/// verify 的结果：各签名方案是否通过 + 证书信息。
class VerifyResult {
  final bool ok;
  final bool v1;
  final bool v2;
  final bool v3;
  final bool v31;
  final bool v32;
  final String? certDn;
  final String? certSha256;
  final String raw;

  const VerifyResult({
    required this.ok,
    required this.v1,
    required this.v2,
    required this.v3,
    required this.v31,
    required this.v32,
    this.certDn,
    this.certSha256,
    required this.raw,
  });
}

abstract class Signer {
  /// 签名 [inputApk]，结果写到 [outputApk]。
  /// [onLog] 逐步输出日志行（实现可忽略）。
  Future<SignResult> sign({
    required String inputApk,
    required String outputApk,
    required KeystoreProfile profile,
    required SignMode mode,
    void Function(String line)? onLog,
  });

  /// 校验 APK 的签名方案与证书。
  Future<VerifyResult> verify(String apkPath, {void Function(String line)? onLog});

  /// 用 keytool 生成一个新的 PKCS12/JKS keystore。
  Future<SignResult> createKeystore({
    required String path,
    required String alias,
    required String dn,
    required String storePass,
    required String keyPass,
    required int validityDays,
  });

  /// 列出 keystore 中的别名及证书信息（导入时用）。
  Future<List<KeystoreAliasInfo>> listAliases({
    required String path,
    required String storePass,
  });

  /// Android 上把 content:// URI 拷贝为可读写文件，返回实际路径；
  /// 桌面端原样返回。
  Future<String> prepareInputPath(String pathOrUri);

  /// 把签名产物保存到「源 APK 所在目录」，返回最终保存路径。
  /// 桌面端签名时已经写到同目录，默认原样返回。
  Future<String> publishSignedApk({
    required String signedApk,
    String? sourceUri,
    required String fileName,
  }) async => signedApk;

  /// 工厂：异步创建。桌面端会先解析打包资源目录。
  static Future<Signer> create() async {
    if (kIsWeb) {
      throw UnsupportedError('web not supported');
    }
    if (Platform.isAndroid) {
      return AndroidSigner();
    }
    final dir = await DesktopSigner.assetsDir();
    return DesktopSigner(dir);
  }
}

/// MethodChannel 调用异常的统一包装。
void rethrowChannelError(Object error) {
  if (error is PlatformException) {
    throw SignerException(error.message ?? 'unknown error');
  }
  throw error;
}

class SignerException implements Exception {
  final String message;
  SignerException(this.message);
  @override
  String toString() => message;
}
