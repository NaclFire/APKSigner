import 'dart:io';

import 'package:apk_signer/models/keystore_profile.dart';
import 'package:apk_signer/models/sign_mode.dart';
import 'package:apk_signer/pages/create_keystore_dialog.dart';
import 'package:apk_signer/pages/import_keystore_dialog.dart';
import 'package:apk_signer/services/keystore_store.dart';
import 'package:apk_signer/services/signer.dart';
import 'package:android_file_picker/android_file_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 主界面：选 APK → 选签名文件 → 选签名方式 → 签名 → 查看结果。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final KeystoreStore _store = KeystoreStore();
  late final Future<Signer> _signerFuture;

  String? _apkPath;
  /// 文件选择器返回的原始 content:// URI（Android），用来定位「源 APK 所在目录」。
  String? _apkUri;
  String? _apkName;
  KeystoreProfile? _profile;
  SignMode _mode = SignMode.v1V2V3;

  bool _busy = false;
  bool _loaded = false;
  String? _loadError;

  String? _outputPath;
  /// 分享用的本地路径（Android 上输出文件在共享目录，分享前先留一份应用内副本）
  String? _sharePath;
  VerifyResult? _verifyResult;
  String? _lastError;

  /// 签名过程日志（终端面板显示）
  final List<String> _log = [];
  final ScrollController _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _signerFuture = Signer.create();
    _init();
  }

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  void _appendLog(String line) {
    if (!mounted) return;
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    setState(() => _log.add('[${two(t.hour)}:${two(t.minute)}:${two(t.second)}] $line'));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _init() async {
    try {
      await _store.load();
      await _signerFuture; // 预热（桌面端解析资源目录）
    } catch (e) {
      _loadError = '$e';
    }
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _pickApk() async {
    final res = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['apk', 'aab'],
    );
    if (res.isEmpty) return;
    final path = res.single.path;
    if (path == null) {
      _toast('所选文件不在本地磁盘，无法签名');
      return;
    }
    if (!path.toLowerCase().endsWith('.apk') &&
        !path.toLowerCase().endsWith('.aab')) {
      _toast('请选择 .apk 或 .aab 文件');
      return;
    }
    setState(() {
      _apkPath = path;
      _apkUri = _sourceUriOf(res.single);
      _apkName = res.single.name;
      _outputPath = null;
      _sharePath = null;
      _verifyResult = null;
      _lastError = null;
    });
  }

  /// 取文件选择器返回的原始存储 URI（Android 上用来反推源文件所在目录）。
  String? _sourceUriOf(PlatformFile file) {
    if (!Platform.isAndroid) return null;
    try {
      if (file is AndroidPlatformFile) return file.safHandle?.uri.toString();
    } catch (_) {
      // 插件内部结构变化时静默降级为「应用目录」
    }
    return null;
  }

  Future<void> _createProfile() async {
    final signer = await _signerFuture;
    if (!mounted) return;
    final created =
        await showCreateKeystoreDialog(context, signer, _store);
    if (created != null && mounted) {
      setState(() {
        _profile = created;
        _outputPath = null;
        _verifyResult = null;
        _lastError = null;
      });
    }
  }

  Future<void> _importProfile() async {
    final signer = await _signerFuture;
    if (!mounted) return;
    final imported =
        await showImportKeystoreDialog(context, signer, _store);
    if (imported != null && mounted) {
      setState(() {
        _profile = imported;
        _outputPath = null;
        _verifyResult = null;
        _lastError = null;
      });
    }
  }

  /// 计算输出文件名：xxx.apk -> xxx_sign.apk
  String _outputNameFor(String apkPath) {
    final base = p.basenameWithoutExtension(apkPath);
    final dir = p.dirname(apkPath);
    return p.join(dir, '${base}_sign.apk');
  }

  Future<void> _sign() async {
    final apk = _apkPath;
    final profile = _profile;
    if (apk == null || profile == null) return;

    final signer = await _signerFuture;
    // Android 上 content URI 先落盘
    final realInput = await signer.prepareInputPath(apk);
    final baseName =
        p.basenameWithoutExtension(_apkName ?? p.basename(realInput));
    final outputName = '${baseName}_sign.apk';
    // Android：先签到应用私有缓存，签名成功后再发布到源 APK 所在目录
    // （应用无法直接往共享目录写文件，必须经 MediaStore）。
    final realOutput = Platform.isAndroid
        ? p.join((await getTemporaryDirectory()).path, outputName)
        : _outputNameFor(realInput);

    setState(() {
      _busy = true;
      _outputPath = null;
      _sharePath = null;
      _verifyResult = null;
      _lastError = null;
      _log.clear();
    });
    _appendLog('开始签名任务…');

    final res = await signer.sign(
      inputApk: realInput,
      outputApk: realOutput,
      profile: profile,
      mode: _mode,
      onLog: _appendLog,
    );

    if (!mounted) return;
    if (res.success) {
      _appendLog('');
      final verify = await signer.verify(realOutput, onLog: _appendLog);
      if (!mounted) return;
      var finalPath = realOutput;
      if (Platform.isAndroid) {
        try {
          finalPath = await signer.publishSignedApk(
            signedApk: realOutput,
            sourceUri: _apkUri,
            fileName: outputName,
          );
          _appendLog('已保存到：$finalPath');
        } catch (e) {
          _appendLog('保存到原目录失败，已保留应用内副本：$e');
        }
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _outputPath = finalPath;
        _sharePath = realOutput;
        _verifyResult = verify;
      });
      _toast('签名完成：$finalPath');
    } else {
      setState(() {
        _busy = false;
        _lastError = res.message;
      });
      _toast('签名失败');
    }
  }

  /// Android：分享签名产物。共享目录里的文件不一定能直接读，
  /// 因此优先分享应用内的同一份副本（内容完全相同）。
  Future<void> _openOutputFolder() async {
    final out = _outputPath;
    if (out == null) return;
    if (Platform.isWindows) {
      Process.start('explorer.exe', ['/select', out]);
    } else if (Platform.isMacOS) {
      Process.start('open', ['-R', out]);
    } else {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(_sharePath ?? out)]),
      );
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  bool get _canSign =>
      _apkPath != null && _profile != null && !_busy && _loaded && _loadError == null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('APK 签名工具'),
        actions: [
          if (!_busy)
            IconButton(
              tooltip: '刷新签名文件列表',
              icon: const Icon(Icons.refresh),
              onPressed: () async {
                await _store.load();
                setState(() {});
              },
            ),
        ],
      ),
      body: _loaded && _loadError != null
          ? _buildError(theme, _loadError!)
          : RefreshIndicator(
              onRefresh: () async {
                await _store.load();
                setState(() {});
              },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildApkCard(theme),
                  const SizedBox(height: 12),
                  _buildKeystoreCard(theme),
                  const SizedBox(height: 12),
                  _buildModeCard(theme),
                  const SizedBox(height: 20),
                  _buildSignButton(theme),
                  if (_log.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _buildLogCard(theme),
                  ],
                  if (_outputPath != null) ...[
                    const SizedBox(height: 20),
                    _buildResultCard(theme),
                  ],
                  if (_lastError != null) ...[
                    const SizedBox(height: 16),
                    _buildErrorCard(theme, _lastError!),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _buildApkCard(ThemeData theme) {
    final apk = _apkPath;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.file_open),
              const SizedBox(width: 8),
              const Text('APK 文件', style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton.icon(
                onPressed: _busy ? null : _pickApk,
                icon: const Icon(Icons.folder_open),
                label: const Text('选择'),
              ),
            ]),
            const SizedBox(height: 8),
            if (apk == null)
              const Text('尚未选择 APK 文件',
                  style: TextStyle(color: Colors.grey))
            else
              SelectableText(
                p.basename(apk),
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            if (apk != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: SelectableText(
                  apk,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeystoreCard(ThemeData theme) {
    final profiles = _store.profiles;
    final selected = _profile;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.key),
              const SizedBox(width: 8),
              const Text('签名文件', style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton.icon(
                onPressed: _busy ? null : _createProfile,
                icon: const Icon(Icons.add),
                label: const Text('新建'),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _importProfile,
                icon: const Icon(Icons.file_upload_outlined),
                label: const Text('导入'),
              ),
            ]),
            const SizedBox(height: 8),
            if (profiles.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('暂无签名文件，点「新建」或「导入」添加',
                    style: TextStyle(color: Colors.grey)),
              )
            else
              DropdownButtonFormField<KeystoreProfile>(
                initialValue: selected,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                items: [
                  for (final pr in profiles)
                    DropdownMenuItem(
                      value: pr,
                      child: Text(pr.name,
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                          _profile = v;
                          _outputPath = null;
                          _verifyResult = null;
                          _lastError = null;
                        }),
              ),
            if (selected != null) ...[
              const SizedBox(height: 8),
              _profileMeta(selected),
            ],
          ],
        ),
      ),
    );
  }

  Widget _profileMeta(KeystoreProfile pr) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _metaRow('别名', pr.alias),
          if (pr.certSubject != null && pr.certSubject!.isNotEmpty)
            _metaRow('证书', pr.certSubject!),
          _metaRow('文件', p.basename(pr.keystorePath)),
        ],
      ),
    );
  }

  Widget _metaRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: Text(label, style: TextStyle(color: Colors.grey.shade700)),
          ),
          Expanded(
            child: SelectableText(value,
                style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _buildModeCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.security),
              const SizedBox(width: 8),
              const Text('签名方式', style: TextStyle(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),
            DropdownButtonFormField<SignMode>(
              initialValue: _mode,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              items: [
                for (final m in SignMode.all)
                  DropdownMenuItem(
                    value: m,
                    child: Text(m.label),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (v) {
                      if (v != null) {
                        setState(() {
                          _mode = v;
                          _outputPath = null;
                          _verifyResult = null;
                          _lastError = null;
                        });
                      }
                    },
            ),
            const SizedBox(height: 6),
            Text(_mode.hint,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildSignButton(ThemeData theme) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton.icon(
        onPressed: _canSign ? _sign : null,
        icon: const Icon(Icons.verified_user),
        label: Text(_busy ? '正在签名…' : '开始签名'),
      ),
    );
  }

  Widget _buildLogCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.terminal, size: 18),
              const SizedBox(width: 8),
              Text(_busy ? '签名进行中…' : '操作日志',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton(
                onPressed: _busy ? null : () => setState(() => _log.clear()),
                child: const Text('清空'),
              ),
            ]),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF15181E),
                borderRadius: BorderRadius.circular(8),
              ),
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(
                controller: _logScroll,
                child: SelectableText(
                  _log.join('\n'),
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    height: 1.6,
                    color: Color(0xFFD8DEE9),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard(ThemeData theme) {
    final verify = _verifyResult;
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.check_circle, color: Colors.green),
              const SizedBox(width: 8),
              const Text('签名成功', style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton.icon(
                onPressed: _openOutputFolder,
                icon: const Icon(Icons.folder_open),
                label: Text(Platform.isAndroid ? '分享' : '打开文件夹'),
              ),
            ]),
            const SizedBox(height: 8),
            SelectableText(
              _outputPath!,
              style: const TextStyle(fontSize: 13),
            ),
            if (verify != null) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _schemeChip('V1', verify.v1),
                  _schemeChip('V2', verify.v2),
                  _schemeChip('V3', verify.v3),
                  if (verify.v31) _schemeChip('V3.1', true),
                  if (verify.v32) _schemeChip('V3.2', true),
                ],
              ),
              if (verify.certDn != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText('证书：${verify.certDn}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _schemeChip(String label, bool ok) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: ok ? Colors.green.shade100 : Colors.red.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            ok ? Icons.check : Icons.close,
            size: 14,
            color: ok ? Colors.green.shade700 : Colors.red.shade700,
          ),
          const SizedBox(width: 4),
          Text('$label ${ok ? '✓' : '✗'}',
              style: TextStyle(
                  fontSize: 12,
                  color: ok ? Colors.green.shade900 : Colors.red.shade900)),
        ],
      ),
    );
  }

  Widget _buildError(ThemeData theme, String msg) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text('初始化失败',
                  style:
                      const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              const SizedBox(height: 8),
              SelectableText(msg, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _init,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );

  Widget _buildErrorCard(ThemeData theme, String msg) {
    return Card(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.error, color: Colors.red),
              const SizedBox(width: 8),
              const Text('签名失败', style: TextStyle(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 8),
            SelectableText(msg, style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
