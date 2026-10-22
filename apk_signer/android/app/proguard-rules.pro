# Flutter 的 release 构建默认开启 R8（minifyEnabled = true），而 BouncyCastle 的
# Provider 完全靠"类名字符串 + 反射"注册算法实现。R8 会重命名/裁剪这些类，导致
#   KeyStore.getInstance("PKCS12", BC) / ("BKS", BC)
# 直接抛 KeyStoreException: not found（应用内 BC 形同不存在）。
# APK 里出现 META-INF/services/y1 这类被混淆的资源名，就是 R8 动过手的证据。
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# apksig 通过反射 / 服务发现使用部分内部类，保持原样最稳妥
-keep class com.android.apksig.** { *; }
-dontwarn com.android.apksig.**

# BouncyCastle 引用了一堆 Android 上不存在的可选依赖（JNDI、Kerberos 等）
-dontwarn javax.naming.**
-dontwarn javax.security.auth.kerberos.**
-dontwarn org.ietf.jgss.**
