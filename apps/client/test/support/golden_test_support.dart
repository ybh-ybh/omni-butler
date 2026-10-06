import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_butler/app/omni_butler_app.dart';

/// 预解码应用品牌图片，确保视觉基线捕获实际图标而非异步空白帧。
Future<void> prepareBrandImageForGolden(WidgetTester tester) async {
  await tester.runAsync(() async {
    await precacheImage(
      const AssetImage('assets/icon/app_icon.png'),
      tester.element(find.byType(OmniButlerApp)),
    );
  });
  await tester.pump();
}
