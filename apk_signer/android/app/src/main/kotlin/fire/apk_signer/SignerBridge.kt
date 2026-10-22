package fire.apk_signer

import android.content.Context
import android.net.Uri
import com.android.apksig.ApkSigner
import com.android.apksig.ApkVerifier
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.BasicConstraints
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.asn1.x509.KeyUsage
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.operator.ContentSigner
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.File
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Security
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * Android 端签名桥接：apksig 签名/验签 + BouncyCastle 生成自签名证书。
 */
class SignerBridge(private val context: Context) {

    init {
        // 支持 BKS（BouncyCastle keystore）类型
        if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
            Security.addProvider(BouncyCastleProvider())
        }
    }

    // ---------- KeyStore 加载（自动识别 PKCS12 / JKS / BKS） ----------

    private fun loadKeyStore(
        path: String,
        storePass: String,
        keyPass: String? = null
    ): KeyStore {
        val bytes = File(path).readBytes()
        val attempts = arrayListOf<Pair<String, java.security.Provider?>>(
            "PKCS12" to null,
            "JKS" to null,
            "BKS" to null,
            "BKS-V1" to null,
            // Android 系统自带的 BC provider 可能不包含所有 keystore 实现；
            // 直接使用应用内 BouncyCastle 实例再尝试一次。
            "PKCS12" to BouncyCastleProvider(),
            "JKS" to BouncyCastleProvider(),
            "BKS" to BouncyCastleProvider(),
            "BKS-V1" to BouncyCastleProvider()
        )
        val failures = ArrayList<String>()
        for ((type, provider) in attempts) {
            try {
                val ks = if (provider != null) KeyStore.getInstance(type, provider)
                else KeyStore.getInstance(type)
                ByteArrayInputStream(bytes).use {
                    ks.load(it, storePass.toCharArray())
                }
                return ks
            } catch (e: Exception) {
                failures.add("$type/${provider?.name ?: "default"}: ${e.javaClass.simpleName}")
            }
        }

        // Android 没有桌面 JDK 的 SUN JKS Provider。对 keytool 生成的标准
        // JKS 做兼容解析，并转换成内存中的 PKCS12 KeyStore，供现有签名代码使用。
        try {
            return loadJksKeyStore(bytes, storePass, keyPass)
        } catch (e: Exception) {
            failures.add("JKS/native: ${e.javaClass.simpleName}")
        }
        throw SecurityException(
            "无法读取 keystore（密码错误、文件损坏或格式不受支持）。" +
                " 尝试格式：${failures.joinToString(", ")}" 
        )
    }

    private data class JksEntry(
        val alias: String,
        val isPrivateKey: Boolean,
        val privateKeyBytes: ByteArray?,
        val certificates: List<X509Certificate>
    )

    /**
     * 读取 SUN JKS 格式（magic FEEDFEED），不依赖 Android 已移除的 JKS Provider。
     * JKS 私钥使用 SHA-1 + 3DES 派生保护；解密后的内容是 PKCS#8。
     */
    private fun readJksEntries(
        bytes: ByteArray,
        storePass: String,
        keyPass: String?
    ): List<JksEntry> {
        val input = DataInputStream(ByteArrayInputStream(bytes))
        if (input.readInt() != 0xFEEDFEED.toInt()) {
            throw SecurityException("不是标准 JKS 文件")
        }
        val version = input.readInt()
        if (version != 1 && version != 2) throw SecurityException("JKS 版本不支持")
        val count = input.readInt()
        if (count < 0 || count > 10000) throw SecurityException("JKS 条目数量无效")
        val entries = ArrayList<JksEntry>(count)
        repeat(count) {
            when (input.readInt()) {
                1 -> {
                    val alias = input.readUTF()
                    input.readLong() // creation date
                    val encryptedLength = input.readInt()
                    if (encryptedLength < 0 || encryptedLength > input.available()) {
                        throw SecurityException("JKS 私钥数据损坏")
                    }
                    val encrypted = ByteArray(encryptedLength)
                    input.readFully(encrypted)
                    val chain = readJksCertificateChain(input)
                    val privateKey = keyPass?.let {
                        decryptJksPrivateKey(encrypted, it)
                    }
                    entries.add(JksEntry(alias, true, privateKey, chain))
                }
                2 -> {
                    val alias = input.readUTF()
                    input.readLong()
                    val chain = readJksCertificateChain(input, single = true)
                    entries.add(JksEntry(alias, false, null, chain))
                }
                else -> throw SecurityException("JKS 条目类型不支持")
            }
        }

        val expected = ByteArray(20)
        input.readFully(expected)
        // JKS 的完整性摘要覆盖 magic/version/entry 数据，而不仅是密码和常量。
        // 前面的 DataInputStream 已经消费了主体，因此从原始字节中取出摘要前的部分。
        // 上面 update 的主体包含了 header；密码和常量必须位于主体之前。
        val actual = MessageDigest.getInstance("SHA-1").run {
            update(storePass.toJksPasswordBytes())
            update("Mighty Aphrodite".toByteArray(Charsets.UTF_8))
            update(bytes, 0, bytes.size - expected.size)
            digest()
        }
        if (!MessageDigest.isEqual(expected, actual)) {
            throw SecurityException("JKS 库密码错误")
        }
        return entries
    }

    private fun readJksCertificateChain(
        input: DataInputStream,
        single: Boolean = false
    ): List<X509Certificate> {
        val count = if (single) 1 else input.readInt()
        if (count < 0 || count > 100) throw SecurityException("JKS 证书链无效")
        val factory = CertificateFactory.getInstance("X.509")
        val result = ArrayList<X509Certificate>(count)
        repeat(count) {
            val type = input.readUTF()
            if (type != "X.509" && type != "X509") {
                throw SecurityException("不支持的证书类型：$type")
            }
            val length = input.readInt()
            if (length < 0 || length > input.available()) {
                throw SecurityException("JKS 证书数据损坏")
            }
            val encoded = ByteArray(length)
            input.readFully(encoded)
            result.add(factory.generateCertificate(ByteArrayInputStream(encoded)) as X509Certificate)
        }
        return result
    }

    private fun loadJksKeyStore(
        bytes: ByteArray,
        storePass: String,
        keyPass: String?
    ): KeyStore {
        val entries = readJksEntries(bytes, storePass, keyPass)
        val result = KeyStore.getInstance("PKCS12")
        result.load(null, null)
        for (entry in entries) {
            if (entry.isPrivateKey && entry.privateKeyBytes != null) {
                val privateKey = decodePrivateKey(entry.privateKeyBytes)
                if (entry.certificates.isEmpty()) {
                    throw SecurityException("JKS 私钥没有证书链")
                }
                val chain = entry.certificates
                    .map { it as java.security.cert.Certificate }
                    .toTypedArray()
                result.setKeyEntry(entry.alias, privateKey, keyPass!!.toCharArray(), chain)
            } else if (entry.certificates.isNotEmpty()) {
                result.setCertificateEntry(entry.alias, entry.certificates.first())
            }
        }
        return result
    }

    private fun decodePrivateKey(encoded: ByteArray): java.security.PrivateKey {
        val spec = PKCS8EncodedKeySpec(encoded)
        for (algorithm in listOf("RSA", "EC", "DSA")) {
            try {
                return KeyFactory.getInstance(algorithm).generatePrivate(spec)
            } catch (_: Exception) {
                // 尝试下一个算法
            }
        }
        throw SecurityException("JKS 私钥算法不支持")
    }

    private fun decryptJksPrivateKey(encrypted: ByteArray, password: String): ByteArray {
        if (encrypted.size < 40) throw SecurityException("JKS 私钥数据损坏")
        val salt = encrypted.copyOfRange(0, 20)
        val checksum = encrypted.copyOfRange(encrypted.size - 20, encrypted.size)
        val ciphertext = encrypted.copyOfRange(20, encrypted.size - 20)
        val passwordBytes = password.toJksPasswordBytes()
        val digest = MessageDigest.getInstance("SHA-1")
        val plain = ByteArray(ciphertext.size)
        var previous = digest.digest(passwordBytes + salt)
        var offset = 0
        while (offset < ciphertext.size) {
            val size = minOf(previous.size, ciphertext.size - offset)
            for (i in 0 until size) plain[offset + i] = (ciphertext[offset + i].toInt() xor previous[i].toInt()).toByte()
            offset += size
            digest.reset()
            digest.update(passwordBytes)
            digest.update(previous)
            previous = digest.digest()
        }
        digest.reset()
        digest.update(passwordBytes)
        val actual = digest.digest(plain)
        if (!MessageDigest.isEqual(checksum, actual)) {
            throw SecurityException("JKS 密钥密码错误")
        }
        return plain
    }

    private fun String.toJksPasswordBytes(): ByteArray {
        val output = ByteArrayOutputStream(length * 2)
        for (c in this) {
            output.write((c.code ushr 8) and 0xff)
            output.write(c.code and 0xff)
        }
        return output.toByteArray()
    }

    // ---------- prepareInput：content:// URI 落盘 ----------

    fun prepareInput(pathOrUri: String): String {
        if (!pathOrUri.startsWith("content://")) return pathOrUri
        val uri = Uri.parse(pathOrUri)
        val name = queryDisplayName(uri) ?: "input_${System.currentTimeMillis()}.apk"
        val out = File(context.cacheDir, name)
        context.contentResolver.openInputStream(uri)?.use { input ->
            out.outputStream().use { input.copyTo(it) }
        } ?: throw SecurityException("无法读取所选文件")
        return out.absolutePath
    }

    private fun queryDisplayName(uri: Uri): String? = try {
        context.contentResolver.query(uri, null, null, null, null)?.use { c ->
            val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
        }
    } catch (_: Exception) {
        null
    }

    // ---------- 签名 ----------

    fun sign(
        input: String,
        output: String,
        ks: String,
        storePass: String,
        keyPass: String,
        alias: String,
        v1: Boolean,
        v2: Boolean,
        v3: Boolean
    ): Boolean {
        val keyStore = loadKeyStore(ks, storePass, keyPass)
        val key = keyStore.getKey(alias, keyPass.toCharArray())
            ?: throw SecurityException("keystore 中找不到别名：$alias")
        val privateKey = key as? java.security.PrivateKey
            ?: throw SecurityException("别名 $alias 不是私钥条目")
        val chain = keyStore.getCertificateChain(alias)
            ?: throw SecurityException("别名 $alias 没有证书链")
        val certList = ArrayList<X509Certificate>()
        for (c in chain) if (c is X509Certificate) certList.add(c)
        if (certList.isEmpty()) throw SecurityException("别名 $alias 没有 X.509 证书链")
        val outFile = File(output)
        outFile.parentFile?.mkdirs()
        val config = ApkSigner.SignerConfig.Builder(alias, privateKey, certList).build()
        val signer = ApkSigner.Builder(listOf(config))
            .setV1SigningEnabled(v1)
            .setV2SigningEnabled(v2)
            .setV3SigningEnabled(v3)
            .setInputApk(File(input))
            .setOutputApk(outFile)
            .build()
        signer.sign()
        return true
    }

    // ---------- 验签 ----------

    fun verify(
        path: String
    ): Map<String, Any?> {
        // 与桌面端 apksigner 相同的"窗口探测"：每个方案只在它独占的 SDK 区间
        // 内验证（18-23 只有 v1 生效，24-27 只有 v2，28-32 只有 v3.0，
        // 33-35 只有 v3.1），这样单个方案的通过与否不会被其他方案掩盖。
        val windows = listOf(
            Triple(18, 23, "v1"),
            Triple(24, 27, "v2"),
            Triple(28, 32, "v3"),
            Triple(33, 35, "v31")
        )
        var v1 = false
        var v2 = false
        var v3 = false
        var v31 = false
        var firstCert: X509Certificate? = null
        val raw = StringBuilder()
        for ((lo, hi, key) in windows) {
            val result = ApkVerifier.Builder(File(path))
                .setMinCheckedPlatformVersion(lo)
                .setMaxCheckedPlatformVersion(hi)
                .build()
                .verify()
            when (key) {
                "v1" -> v1 = result.isVerifiedUsingV1Scheme
                "v2" -> v2 = result.isVerifiedUsingV2Scheme
                "v3" -> v3 = result.isVerifiedUsingV3Scheme
                "v31" -> v31 = result.isVerifiedUsingV31Scheme
            }
            firstCert = firstCert ?: (result.signerCertificates
                .firstOrNull() as? X509Certificate)
            raw.appendLine("[$lo-$hi] verified=${result.isVerified}")
            for (e in result.allErrors) raw.appendLine("  ERROR: $e")
            for (w in result.warnings) raw.appendLine("  WARN: $w")
        }
        return mapOf(
            "ok" to (v1 || v2 || v3 || v31),
            "v1" to v1,
            "v2" to v2,
            "v3" to v3,
            "v31" to v31,
            // apksig 8.7.3 尚不支持 V3.2 验签
            "v32" to false,
            "certDn" to firstCert?.subjectX500Principal?.name,
            "certSha256" to firstCert?.let { sha256Hex(it) },
            "raw" to raw.toString().ifBlank { "OK" }
        )
    }

    // ---------- 生成 keystore（自签名证书） ----------

    fun createKeystore(
        path: String,
        alias: String,
        dn: String,
        storePass: String,
        keyPass: String,
        validityDays: Int
    ): Boolean {
        val file = File(path)
        if (file.exists()) throw SecurityException("目标文件已存在：$path")
        file.parentFile?.mkdirs()

        val kpg = KeyPairGenerator.getInstance("RSA")
        kpg.initialize(2048, SecureRandom())
        val keyPair: KeyPair = kpg.generateKeyPair()

        val subject = X500Name(dn)
        val now = Date()
        val end = Calendar.getInstance().apply {
            time = now
            add(Calendar.DAY_OF_YEAR, validityDays)
        }.time

        val builder = JcaX509v3CertificateBuilder(
            subject,
            BigInteger.valueOf(System.currentTimeMillis()),
            now,
            end,
            subject,
            keyPair.public
        )
        builder.addExtension(Extension.basicConstraints, true, BasicConstraints(true))
        builder.addExtension(
            Extension.keyUsage, true,
            KeyUsage(KeyUsage.digitalSignature or KeyUsage.keyCertSign or KeyUsage.cRLSign)
        )
        val signer: ContentSigner = JcaContentSignerBuilder("SHA256withRSA")
            .build(keyPair.private)
        val holder = builder.build(signer)
        val cert = JcaX509CertificateConverter().getCertificate(holder)

        val ks = KeyStore.getInstance("PKCS12")
        ks.load(null, null)
        val chain = arrayOf<java.security.cert.Certificate>(cert)
        ks.setKeyEntry(alias, keyPair.private, keyPass.toCharArray(), chain)
        file.outputStream().use { ks.store(it, storePass.toCharArray()) }
        return true
    }

    // ---------- 列出别名 ----------

    fun listAliases(path: String, storePass: String): List<Map<String, Any?>> {
        val localPath = prepareInput(path)
        val raw = File(localPath).readBytes()
        if (raw.size >= 4 && java.nio.ByteBuffer.wrap(raw, 0, 4).int == 0xFEEDFEED.toInt()) {
            val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
            return readJksEntries(raw, storePass, null).map { entry ->
                val cert = entry.certificates.firstOrNull()
                mapOf(
                    "alias" to entry.alias,
                    "subject" to (cert?.subjectX500Principal?.name ?: ""),
                    "type" to if (!entry.isPrivateKey && entry.certificates.isNotEmpty()) {
                        "trusted certificate entry"
                    } else {
                        "key entry"
                    },
                    "validFrom" to cert?.let { fmt.format(it.notBefore) },
                    "validTo" to cert?.let { fmt.format(it.notAfter) }
                )
            }
        }
        val ks = loadKeyStore(localPath, storePass)
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
        val list = ArrayList<Map<String, Any?>>()
        val en = ks.aliases()
        while (en.hasMoreElements()) {
            val alias = en.nextElement()
            val cert = ks.getCertificate(alias) as? X509Certificate
            list.add(mapOf(
                "alias" to alias,
                "subject" to (cert?.subjectX500Principal?.name ?: ""),
                "type" to (if (ks.isKeyEntry(alias)) "key entry" else "trusted certificate entry"),
                "validFrom" to (cert?.let { fmt.format(it.notBefore) }),
                "validTo" to (cert?.let { fmt.format(it.notAfter) })
            ))
        }
        return list
    }

    // ---------- 工具 ----------

    private fun sha256Hex(cert: X509Certificate): String {
        val d = java.security.MessageDigest.getInstance("SHA-256").digest(cert.encoded)
        return d.joinToString("") { "%02x".format(it) }
    }
}
