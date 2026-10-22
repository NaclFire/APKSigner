import 'dart:io';

import 'package:apk_signer/models/keystore_profile.dart';
import 'package:apk_signer/services/keystore_store.dart';
import 'package:apk_signer/services/signer.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 导入 keystore 对话框：选文件 → 库密码 → 读别名 → 密钥密码 → 完成。
Future<KeystoreProfile?> showImportKeystoreDialog(
  BuildContext context,
  Signer signer,
  KeystoreStore store,
) {
  return showDialog<KeystoreProfile>(
    context: context,
    builder: (ctx) => _ImportKeystoreDialog(signer: signer, store: store),
  );
}

class _ImportKeystoreDialog extends StatefulWidget {
  final Signer signer;
  final KeystoreStore store;
  const _ImportKeystoreDialog({required this.signer, required this.store});

  @override
  State<_ImportKeystoreDialog> createState() => _ImportKeystoreDialogState();
}

class _ImportKeystoreDialogState extends State<_ImportKeystoreDialog> {
  final _nameCtrl = TextEditingController();
  final _storePassCtrl = TextEditingController();
  final _keyPassCtrl = TextEditingController();

  String? _filePath;
  List<KeystoreAliasInfo> _aliases = [];
  String? _selectedAlias;
  bool _listing = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _storePassCtrl.dispose();
    _keyPassCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    // Android 文件管理器通常通过 Storage Access Framework 返回 content URI，
    // 且未知后缀的 keystore 不能可靠地匹配 custom 扩展名过滤器。因此移动端
    // 使用 any，让用户选择任意文件，并在必要时从返回的内容流生成本地临时文件。
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final res = await FilePicker.pickFiles(
      type: isMobile ? FileType.any : FileType.custom,
      allowedExtensions: isMobile
          ? null
          : ['keystore', 'jks', 'bks', 'p12', 'pfx'],
    );

    if (res.isEmpty) return;
    final picked = res.single;
    var path = picked.path;
    if (path == null && isMobile) {
      final cache = await getTemporaryDirectory();
      final name = picked.name.trim().isEmpty ? 'keystore-import' : picked.name;
      path = p.join(
        cache.path,
        'keystore_${DateTime.now().microsecondsSinceEpoch}_$name',
      );
      await File(path).writeAsBytes(await picked.readAsBytes(), flush: true);
    }
    if (path == null) {
      if (mounted) {
        setState(() => _error = '无法读取所选文件，请换用系统文件管理器重试');
      }
      return;
    }
    setState(() {
      _filePath = path;
      _aliases = [];
      _selectedAlias = null;
      _error = null;
    });
  }

  Future<void> _listAliases() async {
    final path = _filePath;
    if (path == null) {
      setState(() => _error = '请先选择 keystore 文件');
      return;
    }
    setState(() {
      _listing = true;
      _error = null;
    });
    try {
      final list = await widget.signer.listAliases(
        path: path,
        storePass: _storePassCtrl.text,
      );
      if (!mounted) return;
      setState(() {
        _aliases = list;
        _selectedAlias = list.length == 1 ? list.single.alias : null;
        _listing = false;
        if (list.isEmpty) _error = 'keystore 中没有找到密钥条目';
      });
    } on SignerException catch (e) {
      setState(() {
        _listing = false;
        _error = e.message;
      });
    }
  }

  Future<void> _submit() async {
    final path = _filePath;
    final alias = _selectedAlias;
    if (path == null || alias == null) return;
    final name = _nameCtrl.text.trim().isEmpty
        ? p.basenameWithoutExtension(path)
        : _nameCtrl.text.trim();
    setState(() => _busy = true);
    try {
      final profile = await widget.store.importKeystore(
        sourcePath: path,
        name: name,
        storePassword: _storePassCtrl.text,
        keyPassword: _keyPassCtrl.text,
        alias: alias,
        certSubject: _aliases
            .firstWhere((a) => a.alias == alias, orElse: () => throw '')
            .subject,
      );
      if (mounted) Navigator.of(context).pop(profile);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '导入失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final alias = _selectedAlias != null
        ? _aliases.firstWhere(
            (a) => a.alias == _selectedAlias,
            orElse: () => throw '',
          )
        : null;
    return AlertDialog(
      title: const Text('导入签名文件'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameCtrl,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '显示名称',
                  hintText: '可选，留空则使用文件名',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: _busy ? null : _pickFile,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'keystore 文件',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        child: Text(
                          _filePath == null
                              ? (Platform.isAndroid || Platform.isIOS
                                    ? '点击选择签名文件（支持任意后缀）'
                                    : '点击选择（.keystore / .jks / .bks / .p12）')
                              : p.basename(_filePath!),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _storePassCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '库密码 (store password)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _listing || _busy ? null : _listAliases,
                  icon: _listing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: const Text('读取别名'),
                ),
              ),
              if (_aliases.isNotEmpty) ...[
                const SizedBox(height: 4),
                DropdownButtonFormField<String>(
                  initialValue: _selectedAlias,
                  decoration: const InputDecoration(
                    labelText: '别名',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final a in _aliases)
                      DropdownMenuItem(
                        value: a.alias,
                        child: Text(a.alias, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _selectedAlias = v),
                ),
                if (alias != null && alias.subject.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SelectableText(
                      '证书：${alias.subject}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _keyPassCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '密钥密码 (key password)，可与库密码相同',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: SelectableText(
                    _error!,
                    style: const TextStyle(color: Colors.red, fontSize: 13),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: (_filePath != null && _selectedAlias != null) && !_busy
              ? _submit
              : null,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('导入'),
        ),
      ],
    );
  }
}
