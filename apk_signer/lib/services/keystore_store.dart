import 'dart:convert';
import 'dart:io';

import 'package:apk_signer/models/keystore_profile.dart';
import 'package:apk_signer/services/signer.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 管理保存在应用私有数据目录里的签名文件（keystore）档案。
///
/// 目录结构：
///   <appSupport>/keystores/profiles.json   档案索引
///   <appSupport>/keystores/<id>.keystore   keystore 文件本体
class KeystoreStore {
  final List<KeystoreProfile> profiles = [];
  late final Directory _keystoreDir;
  late final File _indexFile;

  Future<void> load() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(support.path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _keystoreDir = dir;
    _indexFile = File(p.join(_keystoreDir.path, 'profiles.json'));
    if (_indexFile.existsSync()) {
      final list = jsonDecode(_indexFile.readAsStringSync()) as List<dynamic>;
      for (final e in list) {
        final p = KeystoreProfile.fromJson(
            Map<String, dynamic>.from(e as Map<dynamic, dynamic>));
        // 文件被手动删掉则跳过
        if (File(p.keystorePath).existsSync()) {
          profiles.add(p);
        }
      }
    }
  }

  void _saveIndex() {
    _indexFile.writeAsStringSync(
        jsonEncode(profiles.map((p) => p.toJson()).toList()));
  }

  /// 生成新 keystore 并登记档案。
  Future<KeystoreProfile> createKeystore({
    required Signer signer,
    required String name,
    required String alias,
    required String dn,
    required String storePassword,
    required String keyPassword,
    required int validityDays,
  }) async {
    final id = _newId();
    final ksPath = p.join(_keystoreDir.path, '$id.keystore');
    final r = await signer.createKeystore(
      path: ksPath,
      alias: alias,
      dn: dn,
      storePass: storePassword,
      keyPass: keyPassword,
      validityDays: validityDays,
    );
    if (!r.success) {
      throw SignerException(r.message);
    }
    final profile = KeystoreProfile(
      id: id,
      name: name,
      keystorePath: ksPath,
      storePassword: storePassword,
      keyPassword: keyPassword,
      alias: alias,
      certSubject: dn,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    profiles.add(profile);
    _saveIndex();
    return profile;
  }

  /// 导入外部 keystore 文件：拷贝进应用目录并登记档案。
  Future<KeystoreProfile> importKeystore({
    required String sourcePath,
    required String name,
    required String storePassword,
    required String keyPassword,
    required String alias,
    String? certSubject,
  }) async {
    final id = _newId();
    final src = File(sourcePath);
    final fileName = p.basename(sourcePath);
    final ext = fileName.contains('.')
        ? fileName.split('.').last
        : 'keystore';
    final ksPath = p.join(_keystoreDir.path, '$id.$ext');
    await src.copy(ksPath);
    final profile = KeystoreProfile(
      id: id,
      name: name,
      keystorePath: ksPath,
      storePassword: storePassword,
      keyPassword: keyPassword,
      alias: alias,
      certSubject: certSubject,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    profiles.add(profile);
    _saveIndex();
    return profile;
  }

  void remove(String id) {
    final i = profiles.indexWhere((p) => p.id == id);
    if (i < 0) return;
    final p = profiles.removeAt(i);
    try {
      File(p.keystorePath).deleteSync();
    } catch (_) {}
    _saveIndex();
  }

  String _newId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = (DateTime.now().millisecondsSinceEpoch & 0xffff).toRadixString(36);
    return '${now}$rand';
  }
}
