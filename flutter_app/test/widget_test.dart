import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antispy_detector/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const AntiSpyApp());
    expect(find.text('ANTI-SPY DETECTION SYSTEM'), findsOneWidget);

    // Unmount widget and advance time to drain timers
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 200));
  });
}
