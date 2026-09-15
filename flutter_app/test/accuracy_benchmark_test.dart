import 'dart:io';
import 'dart:ui' show Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:antispy_detector/services/on_device_detector_service.dart';

void main() {
  test('Run On-Device Detection Benchmark on test_sample.jpg', () async {
    final sampleFile = File('../test_sample.jpg');
    if (!await sampleFile.exists()) {
      fail('test_sample.jpg does not exist in root directory');
    }

    final bytes = await sampleFile.readAsBytes();
    final service = OnDeviceDetectorService();

    final initOk = await service.initialize();
    print('Service initialize: $initOk - Status: ${service.initStatus}');

    if (!initOk) {
      print('Skipping test in headless runner if onnxruntime native library is not bundled in test harness');
      return;
    }

    final resp = await service.detectFrame(
      imageBytes: bytes,
      warningZone: const Rect.fromLTRB(0.0, 0.0, 1.0, 1.0),
      phoneThreshold: 0.70,
      handThreshold: 0.60,
    );

    expect(resp, isNotNull);
    if (resp != null) {
      print('=== DART ON-DEVICE DETECTOR RESULTS ===');
      print('Phones detected: ${resp.phones.length}');
      for (final p in resp.phones) {
        print('  Phone: [${p.x1.toStringAsFixed(1)}, ${p.y1.toStringAsFixed(1)}, ${p.x2.toStringAsFixed(1)}, ${p.y2.toStringAsFixed(1)}] conf=${(p.confidence * 100).toStringAsFixed(1)}%');
      }

      print('Hands detected: ${resp.hands.length}');
      for (final h in resp.hands) {
        print('  Hand: [${h.x1.toStringAsFixed(1)}, ${h.y1.toStringAsFixed(1)}, ${h.x2.toStringAsFixed(1)}, ${h.y2.toStringAsFixed(1)}] conf=${(h.confidence * 100).toStringAsFixed(1)}%');
      }

      print('Holding phone: ${resp.holdingPhone}');
      print('In warning zone: ${resp.inWarningZone}');
      print('Trigger alarm: ${resp.triggerAlarm}');
      print('Process time: ${resp.processTimeMs} ms');
    }
  });
}
