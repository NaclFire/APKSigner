import 'package:apk_signer/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App 可以启动并渲染主界面', (tester) async {
    await tester.pumpWidget(const ApkSignerApp());
    await tester.pumpAndSettle();
    expect(find.text('APK 签名工具'), findsWidgets);
  });
}
