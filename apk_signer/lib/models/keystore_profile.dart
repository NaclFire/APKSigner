/// 一条已保存的签名文件（keystore）档案。
/// keystore 文件本身存放在应用私有数据目录里，密码、别名等元信息以 JSON 保存。
class KeystoreProfile {
  final String id;
  final String name; // 显示名
  final String keystorePath; // 应用数据目录内的绝对路径
  final String storePassword;
  final String keyPassword;
  final String alias;
  final String? certSubject; // 证书 DN（展示用，可为空）
  final int createdAt; // 毫秒时间戳

  const KeystoreProfile({
    required this.id,
    required this.name,
    required this.keystorePath,
    required this.storePassword,
    required this.keyPassword,
    required this.alias,
    required this.createdAt,
    this.certSubject,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'keystorePath': keystorePath,
        'storePassword': storePassword,
        'keyPassword': keyPassword,
        'alias': alias,
        'certSubject': certSubject,
        'createdAt': createdAt,
      };

  factory KeystoreProfile.fromJson(Map<String, dynamic> json) =>
      KeystoreProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        keystorePath: json['keystorePath'] as String,
        storePassword: json['storePassword'] as String,
        keyPassword: json['keyPassword'] as String,
        alias: json['alias'] as String,
        createdAt: (json['createdAt'] as num).toInt(),
        certSubject: json['certSubject'] as String?,
      );
}

/// keytool / keystore 中列出的一个别名条目。
class KeystoreAliasInfo {
  final String alias;
  final String subject; // 证书 DN
  final String type; // e.g. RSA key entry
  final DateTime? validFrom;
  final DateTime? validTo;

  const KeystoreAliasInfo({
    required this.alias,
    required this.subject,
    required this.type,
    this.validFrom,
    this.validTo,
  });

  Map<String, dynamic> toJson() => {
        'alias': alias,
        'subject': subject,
        'type': type,
        'validFrom': validFrom?.toIso8601String(),
        'validTo': validTo?.toIso8601String(),
      };
}
