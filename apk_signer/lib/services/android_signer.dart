import 'package:apk_signer/models/keystore_profile.dart';
import 'package:apk_signer/models/sign_mode.dart';
import 'package:apk_signer/services/signer.dart';
import 'package:flutter/services.dart';

/// Android 端签名实现：通过 MethodChannel 调用 Kotlin 侧的 apksig 库。
class AndroidSigner implements Signer {
  static const _channel = MethodChannel('apk_signer/android');

  @override
  Future<String> prepareInputPath(String pathOrUri) async {
    final p = await _channel.invokeMethod<String>('prepareInput', pathOrUri);
    if (p == null) throw SignerException('无法读取所选文件');
    return p;
  }

  @override
  Future<SignResult> sign({
    required String inputApk,
    required String outputApk,
    required KeystoreProfile profile,
    required SignMode mode,
    void Function(String line)? onLog,
  }) async {
    final log = onLog ?? (_) {};
    log('签名输入：${_basename(inputApk)}');
    log('签名方案：V1=${mode.v1} V2=${mode.v2} V3=${mode.v3}');
    log('启动 apksig 签名（进程内，约需数秒）…');
    try {
      final r = await _channel.invokeMapMethod<String, Object>('sign', {
        'input': inputApk,
        'output': outputApk,
        'ks': profile.keystorePath,
        'storePass': profile.storePassword,
        'keyPass': profile.keyPassword,
        'alias': profile.alias,
        'v1': mode.v1,
        'v2': mode.v2,
        'v3': mode.v3,
      });
      final res = SignResult(
        r?['ok'] as bool? ?? false,
        r?['message'] as String? ?? '',
      );
      log(res.success ? '签名完成' : '签名失败：${res.message}');
      return res;
    } on PlatformException catch (e) {
      log('签名异常：${e.message ?? 'sign failed'}');
      throw SignerException(e.message ?? 'sign failed');
    }
  }

  @override
  Future<VerifyResult> verify(
    String apkPath, {
    void Function(String line)? onLog,
  }) async {
    final log = onLog ?? (_) {};
    log('开始校验签名：${_basename(apkPath)}');
    try {
      final r = await _channel.invokeMapMethod<String, Object>(
        'verify',
        apkPath,
      );
      final res = VerifyResult(
        ok: r?['ok'] as bool? ?? false,
        v1: r?['v1'] as bool? ?? false,
        v2: r?['v2'] as bool? ?? false,
        v3: r?['v3'] as bool? ?? false,
        v31: r?['v31'] as bool? ?? false,
        v32: r?['v32'] as bool? ?? false,
        certDn: r?['certDn'] as String?,
        certSha256: r?['certSha256'] as String?,
        raw: r?['raw'] as String? ?? '',
      );
      log(res.ok ? '校验完成：签名有效' : '校验完成：未发现有效签名');
      return res;
    } on PlatformException catch (e) {
      log('校验失败：${e.message ?? 'verify failed'}');
      return VerifyResult(
        ok: false,
        v1: false,
        v2: false,
        v3: false,
        v31: false,
        v32: false,
        raw: e.message ?? 'verify failed',
      );
    }
  }

  String _basename(String path) =>
      path.contains('/') ? path.split('/').last : path;

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
      final r = await _channel.invokeMapMethod<String, Object>(
        'createKeystore',
        {
          'path': path,
          'alias': alias,
          'dn': dn,
          'storePass': storePass,
          'keyPass': keyPass,
          'validityDays': validityDays,
        },
      );
      return SignResult(
        r?['ok'] as bool? ?? false,
        r?['message'] as String? ?? '',
      );
    } on PlatformException catch (e) {
      throw SignerException(e.message ?? 'createKeystore failed');
    }
  }

  /// 把签名产物保存到源 APK 所在目录（Android 走 MediaStore / 直接写入），返回结果。
  @override
  Future<PublishResult> publishSignedApk({
    required String signedApk,
    String? sourceUri,
    required String fileName,
  }) async {
    try {
      final r = await _channel.invokeMapMethod<String, Object>(
        'publishSignedApk',
        {
          'signed': signedApk,
          'sourceUri': sourceUri ?? '',
          'fileName': fileName,
        },
      );
      final path = r?['path'] as String? ?? signedApk;
      final location = r?['location'] as String? ?? 'source-dir';
      final reason = r?['reason'] as String? ?? '';
      return PublishResult(
        path,
        inSourceDir: location == 'source-dir',
        reason: reason,
      );
    } on PlatformException catch (e) {
      throw SignerException(e.message ?? 'publish failed');
    }
  }

  @override
  Future<bool> hasAllFilesAccess() async {
    try {
      return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> openAllFilesAccessSettings() async {
    try {
      await _channel.invokeMethod<bool>('openAllFilesAccessSettings');
    } on PlatformException {
      // 跳转失败时静默忽略，让用户手动去系统设置
    }
  }

  @override
  Future<List<KeystoreAliasInfo>> listAliases({
    required String path,
    required String storePass,
  }) async {
    try {
      // Android 文件选择器可能返回 content:// URI；统一交给原生层落盘后再读取。
      final localPath = await prepareInputPath(path);
      final r = await _channel.invokeListMethod<Object>('listAliases', {
        'path': localPath,
        'storePass': storePass,
      });
      return (r ?? [])
          .map((e) => e as Map<Object?, Object?>)
          .map(
            (m) => KeystoreAliasInfo(
              alias: m['alias'] as String,
              subject: m['subject'] as String? ?? '',
              type: m['type'] as String? ?? '',
              validFrom: m['validFrom'] != null
                  ? DateTime.tryParse(m['validFrom'] as String)
                  : null,
              validTo: m['validTo'] != null
                  ? DateTime.tryParse(m['validTo'] as String)
                  : null,
            ),
          )
          .toList();
    } on PlatformException catch (e) {
      throw SignerException(e.message ?? 'listAliases failed');
    }
  }
}
