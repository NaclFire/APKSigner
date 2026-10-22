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
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
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
 *
 * keystore 读取策略（按文件头判别，避免"挨个 provider 盲试"）：
 *  - JKS（FEEDFEED）：Android 没有 JKS provider，由本文件自带的解析器处理；
 *    私钥是 sun.security.provider.KeyProtector 保护的 PKCS#8（外面还套了一层
 *    EncryptedPrivateKeyInfo），必须按 JDK 的算法逐字节还原。
 *  - PKCS12 / BKS：交给系统 provider，失败时再用应用内 BouncyCastle。
 *  - JCEKS（CECECECE）：私钥用 PBEWithMD5AndTripleDES 保护，Android 无法还原，
 *    直接给出可操作的提示。
 */
class SignerBridge(private val context: Context) {

    companion object {
        private const val JKS_MAGIC = 0xFEEDFEED.toInt()
        private const val JCEKS_MAGIC = 0xCECECECE.toInt()
        private const val JKS_SALT_LEN = 20
        private const val JKS_DIGEST_LEN = 20
        private const val JKS_KEY_DIGEST_PREFIX = "Mighty Aphrodite"

        /** 复用同一个 BC 实例：既用于注册，也显式传给 KeyStore.getInstance。 */
        private val bcProvider = BouncyCastleProvider()
    }

    init {
        // 支持 BKS（BouncyCastle keystore）类型。
        // 注意：Android 系统可能已有一个名为 BC 的 provider（com.android.org.bouncycastle），
        // 此时 addProvider 会被忽略；下面所有调用都显式传 bcProvider 实例，不依赖名字。
        if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
            Security.addProvider(bcProvider)
        }
    }

    // ---------- KeyStore 访问抽象 ----------

    /** 屏蔽"系统 KeyStore"与"自行解析的 JKS 条目"两种来源。 */
    private interface KeyStoreAccess {
        fun aliases(): List<String>
        fun isKeyEntry(alias: String): Boolean
        fun certificateChain(alias: String): List<X509Certificate>?
        fun privateKey(alias: String, keyPassword: String, storePassword: String): PrivateKey
    }

    private inner class PlatformKeyStoreAccess(private val keyStore: KeyStore) : KeyStoreAccess {
        override fun aliases(): List<String> {
            val result = ArrayList<String>()
            val en = keyStore.aliases()
            while (en.hasMoreElements()) result.add(en.nextElement())
            return result
        }

        override fun isKeyEntry(alias: String): Boolean = keyStore.isKeyEntry(alias)

        override fun certificateChain(alias: String): List<X509Certificate>? =
            keyStore.getCertificateChain(alias)
                ?.mapNotNull { it as? X509Certificate }
                ?.takeIf { it.isNotEmpty() }

        override fun privateKey(
            alias: String,
            keyPassword: String,
            storePassword: String
        ): PrivateKey {
            if (!keyStore.isKeyEntry(alias)) {
                throw SecurityException("keystore 中找不到私钥别名：$alias")
            }
            val candidates = linkedSetOf(keyPassword)
            if (storePassword != keyPassword) candidates.add(storePassword)
            var last: Exception? = null
            for (password in candidates) {
                try {
                    val key = keyStore.getKey(alias, password.toCharArray())
                    if (key is PrivateKey) return key
                } catch (e: Exception) {
                    last = e
                }
            }
            throw SecurityException(
                "别名 $alias 的密钥密码不正确" + describeFailure(last)
            )
        }
    }

    private inner class JksKeyStoreAccess(
        private val entries: List<JksEntry>,
        private val storePassword: String
    ) : KeyStoreAccess {
        private fun find(alias: String): JksEntry? = entries.firstOrNull { it.alias == alias }

        override fun aliases(): List<String> = entries.map { it.alias }

        override fun isKeyEntry(alias: String): Boolean = find(alias)?.isPrivateKey == true

        override fun certificateChain(alias: String): List<X509Certificate>? =
            find(alias)?.certificates?.takeIf { it.isNotEmpty() }

        override fun privateKey(
            alias: String,
            keyPassword: String,
            storePassword: String
        ): PrivateKey {
            val entry = find(alias) ?: throw SecurityException("keystore 中找不到别名：$alias")
            val protectedKey = entry.protectedPrivateKey
                ?: throw SecurityException("别名 $alias 不是私钥条目")
            // 库密码已经通过 JKS 完整性摘要校验，这里只需找对私钥密码。
            // 很多 keystore 的密钥密码与库密码相同，因此失败时再试一次库密码。
            val candidates = linkedSetOf(keyPassword)
            if (storePassword != keyPassword) candidates.add(storePassword)
            var last: Exception? = null
            for (password in candidates) {
                try {
                    return decodePrivateKey(recoverJksPrivateKey(protectedKey, password))
                } catch (e: Exception) {
                    last = e
                }
            }
            throw SecurityException(
                "别名 $alias 的密钥密码不正确（库密码已通过校验）" + describeFailure(last)
            )
        }
    }

    // ---------- KeyStore 加载（自动识别 PKCS12 / JKS / BKS） ----------

    private fun loadKeyStore(path: String, storePass: String): KeyStoreAccess {
        val file = File(path)
        if (!file.isFile) throw SecurityException("keystore 文件不存在或无法读取：$path")
        val bytes = file.readBytes()
        if (bytes.isEmpty()) throw SecurityException("keystore 文件为空：${file.name}")

        when (val magic = if (bytes.size >= 4) readInt(bytes, 0) else 0) {
            // Android 没有 JKS provider，直接用自己的解析器
            JKS_MAGIC -> return JksKeyStoreAccess(readJksEntries(bytes, storePass), storePass)

            JCEKS_MAGIC -> throw SecurityException(
                "无法读取 ${file.name}：这是 JCEKS 格式，Android 端无法还原其中的私钥。\n" +
                    "请先转换成 PKCS12 或 JKS：\n" +
                    "keytool -importkeystore -srckeystore <原文件> -srcstoretype JCEKS " +
                    "-deststoretype PKCS12 -destkeystore <新文件.p12>"
            )

            else -> {
                // 仅用于日志：帮助用户判断选错了文件
                if (magic == 0x504B0304) {
                    throw SecurityException(
                        "无法读取 ${file.name}：这是一个 ZIP/APK 文件，不是 keystore"
                    )
                }
            }
        }

        val attempts = listOf(
            "PKCS12" to null,
            "BKS" to null,
            "BKS-V1" to null,
            // 系统 provider 可能缺少某些实现（或文件用了系统不支持的 PBES2 算法），
            // 再用应用内 BouncyCastle 尝试一次。
            "PKCS12" to bcProvider,
            "BKS" to bcProvider,
            "BKS-V1" to bcProvider
        )
        // 同一种错误可能被系统和 BC 各报一次：按错误内容归并，避免刷屏
        val failures = LinkedHashMap<String, MutableList<String>>()
        for ((type, provider) in attempts) {
            val label = if (provider == null) "$type/系统" else "$type/BC"
            try {
                val ks = if (provider != null) KeyStore.getInstance(type, provider)
                else KeyStore.getInstance(type)
                ByteArrayInputStream(bytes).use { ks.load(it, storePass.toCharArray()) }
                return PlatformKeyStoreAccess(ks)
            } catch (e: Exception) {
                failures.getOrPut(describeFailure(e)) { ArrayList() }.add(label)
            }
        }

        // 全部失败：把最关键的信息拼出来，便于用户自查
        // 文件头是 0x30 0x8x（DER SEQUENCE），几乎可以确定是 PKCS12 容器，
        // 这种文件读取失败基本都是密码问题，明确说出来，避免用户误以为文件损坏。
        val looksLikePkcs12 = bytes.size >= 2 && bytes[0] == 0x30.toByte() &&
            (bytes[1].toInt() and 0x80) != 0
        val diagnosis = if (looksLikePkcs12) {
            "文件头看起来是 PKCS12 格式：读取失败通常是库密码不正确（也可能是文件被截断/损坏）。"
        } else {
            "无法识别该文件的格式；请确认选择的是 JKS / PKCS12(.p12/.pfx) 文件，且库密码正确。"
        }
        throw SecurityException(
            "无法读取 keystore：${file.name}（${bytes.size} 字节，" +
                "文件头 ${hex(bytes, 4)}）。\n" +
                diagnosis + "\n" +
                failures.entries.joinToString("\n") { (desc, labels) ->
                    "${labels.joinToString("/")} $desc"
                }
        )
    }

    // ---------- JKS 解析（不依赖桌面 JDK 的 SUN provider） ----------

    private data class JksEntry(
        val alias: String,
        val isPrivateKey: Boolean,
        /** JKS 里存的 PKCS#8 EncryptedPrivateKeyInfo（DER），签名时才解密。 */
        val protectedPrivateKey: ByteArray?,
        val certificates: List<X509Certificate>
    )

    /**
     * 读取 SUN JKS 格式（magic FEEDFEED）。
     *
     * 注意两处容易踩坑的细节：
     *  1. 完整性摘要覆盖"magic + version + 条目"，且位于文件末尾 20 字节：
     *     SHA1(密码的 UTF-16BE 字节 || "Mighty Aphrodite" || 前面所有字节)。
     *  2. 版本 1 的证书条目没有证书类型（UTF）字段，版本 2 才有。
     */
    private fun readJksEntries(bytes: ByteArray, storePass: String): List<JksEntry> {
        if (bytes.size < 12 + JKS_DIGEST_LEN) throw SecurityException("JKS 文件不完整")

        // 先校验库密码：密码错时条目解析会因乱码数据而报出令人误解的错误
        val bodyLength = bytes.size - JKS_DIGEST_LEN
        val expected = bytes.copyOfRange(bodyLength, bytes.size)
        val md = MessageDigest.getInstance("SHA-1")
        md.update(storePass.toJksPasswordBytes())
        md.update(JKS_KEY_DIGEST_PREFIX.toByteArray(Charsets.UTF_8))
        md.update(bytes, 0, bodyLength)
        if (!MessageDigest.isEqual(expected, md.digest())) {
            throw SecurityException("JKS 库密码错误（keystore 文件本身完好）")
        }

        try {
            val input = DataInputStream(ByteArrayInputStream(bytes, 0, bodyLength))
            if (input.readInt() != JKS_MAGIC) throw SecurityException("不是标准 JKS 文件")
            val version = input.readInt()
            if (version != 1 && version != 2) throw SecurityException("JKS 版本不支持：$version")
            val count = input.readInt()
            if (count < 0 || count > 10000) throw SecurityException("JKS 条目数量无效：$count")

            val entries = ArrayList<JksEntry>(count)
            repeat(count) {
                when (input.readInt()) {
                    1 -> {
                        val alias = input.readUTF()
                        input.readLong() // 创建时间
                        val protectedKey = readLengthPrefixed(input, "JKS 私钥数据损坏")
                        val chain = readJksCertificateChain(input, version, single = false)
                        entries.add(
                            JksEntry(
                                alias = alias,
                                isPrivateKey = true,
                                protectedPrivateKey = protectedKey,
                                certificates = chain
                            )
                        )
                    }

                    2 -> {
                        val alias = input.readUTF()
                        input.readLong()
                        val chain = readJksCertificateChain(input, version, single = true)
                        entries.add(
                            JksEntry(
                                alias = alias,
                                isPrivateKey = false,
                                protectedPrivateKey = null,
                                certificates = chain
                            )
                        )
                    }

                    else -> throw SecurityException("JKS 条目类型不支持")
                }
            }
            return entries
        } catch (e: SecurityException) {
            throw e
        } catch (e: Exception) {
            throw SecurityException("JKS 文件结构损坏：${e.message ?: e.javaClass.simpleName}")
        }
    }

    private fun readJksCertificateChain(
        input: DataInputStream,
        version: Int,
        single: Boolean
    ): List<X509Certificate> {
        val count = if (single) 1 else input.readInt()
        if (count < 0 || count > 100) throw SecurityException("JKS 证书链无效")
        val factory = CertificateFactory.getInstance("X.509")
        val result = ArrayList<X509Certificate>(count)
        repeat(count) {
            // 版本 1 没有证书类型字段，默认就是 X.509
            if (version >= 2) {
                val type = input.readUTF()
                if (type != "X.509" && type != "X509") {
                    throw SecurityException("不支持的证书类型：$type")
                }
            }
            val encoded = readLengthPrefixed(input, "JKS 证书数据损坏")
            result.add(
                factory.generateCertificate(ByteArrayInputStream(encoded)) as X509Certificate
            )
        }
        return result
    }

    private fun readLengthPrefixed(input: DataInputStream, error: String): ByteArray {
        val length = input.readInt()
        if (length < 0 || length > input.available()) throw SecurityException(error)
        val data = ByteArray(length)
        input.readFully(data)
        return data
    }

    /**
     * JKS 私钥条目存的是 JDK `KeyProtector.protect()` 的返回值，即 PKCS#8
     * EncryptedPrivateKeyInfo：SEQUENCE { AlgorithmIdentifier, OCTET STRING }。
     * 真正参与异或的是 OCTET STRING 里的 salt(20) + 密文 + 校验摘要(20)。
     *
     * 少数第三方工具会直接写裸数据（没有 DER 外壳），此时按原样处理。
     */
    private fun unwrapEncryptedPrivateKeyInfo(blob: ByteArray): ByteArray {
        if (blob.isEmpty() || (blob[0].toInt() and 0xff) != 0x30) return blob
        try {
            val reader = DerReader(blob)
            if (reader.readTag() != 0x30) return blob
            reader.readLength()
            if (reader.readTag() != 0x30) throw SecurityException("JKS 私钥保护数据无法识别")
            reader.skip(reader.readLength()) // AlgorithmIdentifier 内容
            if (reader.readTag() != 0x04) throw SecurityException("JKS 私钥保护数据无法识别")
            val length = reader.readLength()
            if (length < 0 || reader.pos + length > blob.size) {
                throw SecurityException("JKS 私钥保护数据长度越界")
            }
            return blob.copyOfRange(reader.pos, reader.pos + length)
        } catch (e: IndexOutOfBoundsException) {
            throw SecurityException("JKS 私钥保护数据损坏")
        }
    }

    /**
     * `sun.security.provider.KeyProtector.recover()` 的等价实现：
     *  xorKey = SHA1(pw||salt) || SHA1(pw||前一段摘要) || ...
     *  plain  = ciphertext XOR xorKey
     *  校验   = SHA1(pw || plain) 与末尾 20 字节比较
     */
    private fun recoverJksPrivateKey(protectedKey: ByteArray, password: String): ByteArray {
        val data = unwrapEncryptedPrivateKeyInfo(protectedKey)
        if (data.size < JKS_SALT_LEN + JKS_DIGEST_LEN) throw SecurityException("JKS 私钥数据损坏")

        val salt = data.copyOfRange(0, JKS_SALT_LEN)
        val encryptedLength = data.size - JKS_SALT_LEN - JKS_DIGEST_LEN
        val checksum = data.copyOfRange(JKS_SALT_LEN + encryptedLength, data.size)
        val passwordBytes = password.toJksPasswordBytes()

        val digest = MessageDigest.getInstance("SHA-1")
        var block = digest.digest(passwordBytes + salt)
        val plain = ByteArray(encryptedLength)
        var offset = 0
        while (offset < encryptedLength) {
            val size = minOf(block.size, encryptedLength - offset)
            for (i in 0 until size) {
                plain[offset + i] =
                    (data[JKS_SALT_LEN + offset + i].toInt() xor block[i].toInt()).toByte()
            }
            offset += size
            digest.reset()
            digest.update(passwordBytes)
            digest.update(block)
            block = digest.digest()
        }

        digest.reset()
        digest.update(passwordBytes)
        if (!MessageDigest.isEqual(checksum, digest.digest(plain))) {
            throw SecurityException("JKS 密钥密码错误")
        }
        return plain
    }

    private fun decodePrivateKey(encoded: ByteArray): PrivateKey {
        val spec = PKCS8EncodedKeySpec(encoded)
        for (algorithm in listOf("RSA", "EC", "DSA")) {
            try {
                return KeyFactory.getInstance(algorithm).generatePrivate(spec)
            } catch (_: Exception) {
                // 尝试下一个算法
            }
        }
        throw SecurityException("JKS 私钥算法不支持（仅支持 RSA / EC / DSA）")
    }

    private fun String.toJksPasswordBytes(): ByteArray {
        val output = ByteArrayOutputStream(length * 2)
        for (c in this) {
            output.write((c.code ushr 8) and 0xff)
            output.write(c.code and 0xff)
        }
        return output.toByteArray()
    }

    /** 极简 DER 读取器，只用于解开 EncryptedPrivateKeyInfo 外壳。 */
    private class DerReader(private val data: ByteArray) {
        var pos = 0

        fun readTag(): Int {
            if (pos >= data.size) throw IndexOutOfBoundsException("DER 数据结束")
            return data[pos++].toInt() and 0xff
        }

        fun readLength(): Int {
            val first = readTag()
            if (first and 0x80 == 0) return first
            val count = first and 0x7f
            if (count == 0 || count > 3) throw SecurityException("DER 长度字段无效")
            var length = 0
            repeat(count) { length = (length shl 8) or readTag() }
            return length
        }

        fun skip(length: Int) {
            if (length < 0 || pos + length > data.size) throw IndexOutOfBoundsException("DER 越界")
            pos += length
        }
    }

    // ---------- 诊断辅助 ----------

    private fun describeFailure(e: Exception?): String {
        if (e == null) return ""
        val raw = e.message?.trim().orEmpty()
        val hint = when {
            // 注意顺序：Android 的 PKCS12 provider 在密码错误时抛的是
            // "PKCS12 key store mac invalid - wrong password or corrupted file."
            // 必须先判 "mac invalid"，否则会被下面的 PKCS12 规则误判成"不是 PKCS12 文件"
            raw.contains("mac invalid", ignoreCase = true) ||
                raw.contains("wrong password", ignoreCase = true) ||
                raw.contains("password was incorrect", ignoreCase = true) ||
                raw.contains("mac verify", ignoreCase = true) -> "库密码不正确"
            raw.contains("stream does not represent a PKCS12 key store", ignoreCase = true) ->
                "文件不是 PKCS12"
            raw.contains("Wrong version of key store", ignoreCase = true) -> "文件不是该格式"
            raw.contains("not found", ignoreCase = true) -> "系统没有该格式的实现"
            else -> null
        }
        val detail = when {
            raw.isEmpty() -> ""
            hint == null -> "：$raw"
            else -> "（$raw）"
        }
        return "${e.javaClass.simpleName}${hint?.let { "（$it）" } ?: ""}$detail"
    }

    private fun hex(bytes: ByteArray, count: Int): String =
        bytes.take(count).joinToString(" ") { "%02X".format(it) }

    private fun readInt(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xff) shl 24) or
            ((bytes[offset + 1].toInt() and 0xff) shl 16) or
            ((bytes[offset + 2].toInt() and 0xff) shl 8) or
            (bytes[offset + 3].toInt() and 0xff)

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
        val keyStore = loadKeyStore(ks, storePass)
        val privateKey = keyStore.privateKey(alias, keyPass, storePass)
        val certList = keyStore.certificateChain(alias)
            ?: throw SecurityException("别名 $alias 没有 X.509 证书链")
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
        val keyStore = loadKeyStore(prepareInput(path), storePass)
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
        return keyStore.aliases().map { alias ->
            val cert = keyStore.certificateChain(alias)?.firstOrNull()
            mapOf(
                "alias" to alias,
                "subject" to (cert?.subjectX500Principal?.name ?: ""),
                "type" to if (keyStore.isKeyEntry(alias)) {
                    "key entry"
                } else {
                    "trusted certificate entry"
                },
                "validFrom" to cert?.let { fmt.format(it.notBefore) },
                "validTo" to cert?.let { fmt.format(it.notAfter) }
            )
        }
    }

    // ---------- 工具 ----------

    private fun sha256Hex(cert: X509Certificate): String {
        val d = MessageDigest.getInstance("SHA-256").digest(cert.encoded)
        return d.joinToString("") { "%02x".format(it) }
    }
}
