import 'package:apk_signer/models/keystore_profile.dart';
import 'package:apk_signer/services/keystore_store.dart';
import 'package:apk_signer/services/signer.dart';
import 'package:flutter/material.dart';

/// 新建 keystore 对话框。
Future<KeystoreProfile?> showCreateKeystoreDialog(
    BuildContext context, Signer signer, KeystoreStore store) {
  return showDialog<KeystoreProfile>(
    context: context,
    builder: (ctx) => _CreateKeystoreDialog(signer: signer, store: store),
  );
}

class _CreateKeystoreDialog extends StatefulWidget {
  final Signer signer;
  final KeystoreStore store;
  const _CreateKeystoreDialog({required this.signer, required this.store});

  @override
  State<_CreateKeystoreDialog> createState() => _CreateKeystoreDialogState();
}

class _CreateKeystoreDialogState extends State<_CreateKeystoreDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _aliasCtrl = TextEditingController();
  final _cnCtrl = TextEditingController();
  final _ouCtrl = TextEditingController();
  final _oCtrl = TextEditingController();
  final _lCtrl = TextEditingController();
  final _stCtrl = TextEditingController();
  final _cCtrl = TextEditingController(text: 'CN');
  final _passCtrl = TextEditingController();
  final _pass2Ctrl = TextEditingController();
  final _yearsCtrl = TextEditingController(text: '25');
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [
      _nameCtrl, _aliasCtrl, _cnCtrl, _ouCtrl, _oCtrl, _lCtrl,
      _stCtrl, _cCtrl, _passCtrl, _pass2Ctrl, _yearsCtrl
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _dn =>
      'CN=${_cnCtrl.text.trim()}, OU=${_ouCtrl.text.trim()}, O=${_oCtrl.text.trim()}, L=${_lCtrl.text.trim()}, ST=${_stCtrl.text.trim()}, C=${_cCtrl.text.trim()}';

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    try {
      final store = widget.store;
      final profile = await store.createKeystore(
        signer: widget.signer,
        name: _nameCtrl.text.trim(),
        alias: _aliasCtrl.text.trim(),
        dn: _dn,
        storePassword: _passCtrl.text,
        keyPassword: _passCtrl.text,
        validityDays: int.parse(_yearsCtrl.text.trim()) * 365,
      );
      if (mounted) Navigator.of(context).pop(profile);
    } on SignerException catch (e) {
      _alert(e.message);
    } catch (e) {
      _alert('生成失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _alert(String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('出错了'),
        content: SelectableText(msg),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建签名文件'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _field(_nameCtrl, '显示名称', hint: '例如：我的正式签名', required: true),
                const SizedBox(height: 12),
                _field(_aliasCtrl, '别名 (alias)', hint: 'keytool 中的 key alias',
                    required: true),
                const SizedBox(height: 12),
                _field(_cnCtrl, '公用名 (CN)', hint: '例如：MyApp 或 个人姓名',
                    required: true),
                const SizedBox(height: 12),
                _field(_ouCtrl, '组织单位 (OU)'),
                const SizedBox(height: 12),
                _field(_oCtrl, '组织 (O)'),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _field(_lCtrl, '城市 (L)')),
                  const SizedBox(width: 12),
                  Expanded(child: _field(_stCtrl, '省/州 (ST)')),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 80,
                    child: _field(_cCtrl, '国家 (C)'),
                  ),
                ]),
                const SizedBox(height: 12),
                _field(_passCtrl, '密码', hint: '至少 6 位，库密码与密钥密码相同',
                    required: true, obscure: true),
                const SizedBox(height: 12),
                _field(_pass2Ctrl, '确认密码',
                    required: true, obscure: true,
                    validator: (v) =>
                        (v == _passCtrl.text) ? null : '两次输入不一致'),
                const SizedBox(height: 12),
                Row(children: [
                  const SizedBox(
                      width: 80, child: Text('有效期', style: TextStyle(fontSize: 13))),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 100,
                    child: TextFormField(
                      controller: _yearsCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        suffixText: '年',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) {
                        final n = int.tryParse((v ?? '').trim());
                        if (n == null || n < 1 || n > 100) {
                          return '请输入 1-100 的整数';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                      '常用 25 年，最长 100 年',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ]),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('生成'),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    String hint = '',
    bool required = false,
    bool obscure = false,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: ctrl,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      validator: validator ??
          (required
              ? (v) => (v == null || v.trim().isEmpty) ? '必填' : null
              : null),
    );
  }
}

