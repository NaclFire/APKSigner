/// 签名方式定义。
/// 对应 apksigner 的 v1/v2/v3 开关组合。
class SignMode {
  final String label;
  final String hint;
  final bool v1;
  final bool v2;
  final bool v3;

  const SignMode(this.label, this.hint,
      {required this.v1, required this.v2, required this.v3});

  static const SignMode v1Only = SignMode(
    '仅 V1',
    'JAR 签名，兼容旧系统；targetSdk≥30 的包无法通过商店校验',
    v1: true,
    v2: false,
    v3: false,
  );

  static const SignMode v1V2 = SignMode(
    'V1 + V2',
    'Android 7.0 以下走 V1，以上走 V2，最常用',
    v1: true,
    v2: true,
    v3: false,
  );

  static const SignMode v2Only = SignMode(
    '仅 V2',
    '仅 APK Signature Scheme v2，要求 APK 的 minSdk ≥ 24',
    v1: false,
    v2: true,
    v3: false,
  );

  static const SignMode v1V2V3 = SignMode(
    'V1 + V2 + V3',
    '全兼容方案，推荐',
    v1: true,
    v2: true,
    v3: true,
  );

  static const List<SignMode> all = [v1Only, v1V2, v2Only, v1V2V3];

  /// 当前是否启用某个签名方案
  bool get hasV1 => v1;
  bool get hasV2 => v2;
  bool get hasV3 => v3;
}
