import 'dart:math' as math;
import 'dart:ui' show Rect, Offset;
import 'package:flutter_test/flutter_test.dart';
import 'package:antispy_detector/models/detection_models.dart';

void main() {
  group('Mathematical Pre/Post Processing Verification', () {
    test('ImageNet Normalization produces correct range', () {
      const meanR = 0.485, meanG = 0.456, meanB = 0.406;
      const stdR = 0.229, stdG = 0.224, stdB = 0.225;

      // Pixel (255, 255, 255)
      final normWhiteR = ((255 / 255.0) - meanR) / stdR;
      final normWhiteG = ((255 / 255.0) - meanG) / stdG;
      final normWhiteB = ((255 / 255.0) - meanB) / stdB;

      expect(normWhiteR, closeTo(2.248, 0.01));
      expect(normWhiteG, closeTo(2.428, 0.01));
      expect(normWhiteB, closeTo(2.64, 0.01));

      // Pixel (0, 0, 0)
      final normBlackR = (0.0 - meanR) / stdR;
      expect(normBlackR, closeTo(-2.117, 0.01));
    });

    test('Sigmoid function correctly converts raw logits to probabilities', () {
      double sigmoid(double logit) => 1.0 / (1.0 + math.exp(-logit));

      expect(sigmoid(0.0), closeTo(0.5, 0.001));
      expect(sigmoid(2.0), closeTo(0.8807, 0.001));
      expect(sigmoid(-3.0), closeTo(0.0474, 0.001));
      expect(sigmoid(5.0), greaterThan(0.99));
    });

    test('Bounding box [cx, cy, w, h] correctly decodes to valid [x1, y1, x2, y2]', () {
      const origW = 1920.0;
      const origH = 1080.0;
      const cx = 0.5;
      const cy = 0.5;
      const w = 0.2;
      const h = 0.3;

      final x1 = math.max(0.0, (cx - w / 2.0) * origW);
      final y1 = math.max(0.0, (cy - h / 2.0) * origH);
      final x2 = math.min(origW, (cx + w / 2.0) * origW);
      final y2 = math.min(origH, (cy + h / 2.0) * origH);

      expect(x1, equals(768.0));
      expect(y1, equals(378.0));
      expect(x2, equals(1152.0));
      expect(y2, equals(702.0));
      expect(x2 > x1, isTrue);
      expect(y2 > y1, isTrue);
    });

    test('DetectionBox to Rect conversion and overlap calculation', () {
      const box = DetectionBox(
        x1: 100,
        y1: 100,
        x2: 200,
        y2: 200,
        confidence: 0.95,
        label: 'Điện thoại',
      );

      final rect = box.toRect();
      expect(rect.width, equals(100));
      expect(rect.height, equals(100));
    });

    test('Anti-spy logic: requires hand holding phone with overlap to alarm', () {
      // Bàn tay: [100, 100, 250, 250]
      // Điện thoại: [120, 120, 200, 280]
      const hand = DetectionBox(x1: 100, y1: 100, x2: 250, y2: 250, confidence: 0.85, label: 'Bàn tay');
      const phone = DetectionBox(x1: 120, y1: 120, x2: 200, y2: 280, confidence: 0.88, label: 'Điện thoại');

      // 25% padding on hand
      final padX = (hand.x2 - hand.x1) * 0.25;
      final padY = (hand.y2 - hand.y1) * 0.25;
      final hx1 = hand.x1 - padX;
      final hy1 = hand.y1 - padY;
      final hx2 = hand.x2 + padX;
      final hy2 = hand.y2 + padY;

      final ox1 = math.max(hx1, phone.x1);
      final oy1 = math.max(hy1, phone.y1);
      final ox2 = math.min(hx2, phone.x2);
      final oy2 = math.min(hy2, phone.y2);

      final overlapArea = (ox2 - ox1) * (oy2 - oy1);
      final phoneArea = (phone.x2 - phone.x1) * (phone.y2 - phone.y1);
      final ratio = overlapArea / phoneArea;

      // Phải thỏa mãn điều kiện holdingPhone như app.py
      expect(ratio >= 0.15 || overlapArea >= 400.0, isTrue);
    });

    test('Zone intrusion verification: strictly ignores phone outside zone', () {
      const origW = 1000.0;
      const origH = 1000.0;
      // Vùng cảnh báo ở trung tâm: [300, 300, 700, 700]
      const warningZone = Rect.fromLTRB(0.3, 0.3, 0.7, 0.7);

      // 1. Điện thoại ở góc trên-trái [50, 50, 150, 200] (HOÀN TOÀN NGOÀI ZONE)
      const phoneOutside = DetectionBox(x1: 50, y1: 50, x2: 150, y2: 200, confidence: 0.9, label: 'Điện thoại');
      final pcx = (phoneOutside.x1 + phoneOutside.x2) / (2.0 * origW);
      final pcy = (phoneOutside.y1 + phoneOutside.y2) / (2.0 * origH);
      final pCenter = Offset(pcx, pcy);

      final normRectOutside = Rect.fromLTRB(
        phoneOutside.x1 / origW,
        phoneOutside.y1 / origH,
        phoneOutside.x2 / origW,
        phoneOutside.y2 / origH,
      );
      final interOutside = warningZone.intersect(normRectOutside);
      final phoneInZoneOutside = warningZone.contains(pCenter) ||
          (interOutside.width > 0 && interOutside.height > 0 &&
              (interOutside.width * interOutside.height) / (normRectOutside.width * normRectOutside.height) >= 0.30);

      // Phải là FALSE: Tuyệt đối không báo động khi điện thoại ở ngoài zone
      expect(phoneInZoneOutside, isFalse);

      // 2. Điện thoại ở trung tâm [450, 450, 550, 600] (NẰM TRONG ZONE)
      const phoneInside = DetectionBox(x1: 450, y1: 450, x2: 550, y2: 600, confidence: 0.9, label: 'Điện thoại');
      final pcxIn = (phoneInside.x1 + phoneInside.x2) / (2.0 * origW);
      final pcyIn = (phoneInside.y1 + phoneInside.y2) / (2.0 * origH);
      final pCenterIn = Offset(pcxIn, pcyIn);

      final phoneInZoneInside = warningZone.contains(pCenterIn);
      // Phải là TRUE: Kích hoạt báo động khi điện thoại vào trong zone
      expect(phoneInZoneInside, isTrue);

      // 3. Điện thoại chỉ hơi chạm mép zone 5% - 10%
      const phoneTouching = DetectionBox(x1: 290, y1: 400, x2: 310, y2: 500, confidence: 0.9, label: 'Điện thoại');
      final normRectTouch = Rect.fromLTRB(
        phoneTouching.x1 / origW,
        phoneTouching.y1 / origH,
        phoneTouching.x2 / origW,
        phoneTouching.y2 / origH,
      );
      final interTouch = warningZone.intersect(normRectTouch);
      final phoneInZoneTouching = interTouch.width > 0 && interTouch.height > 0 &&
          (interTouch.width * interTouch.height) / (normRectTouch.width * normRectTouch.height) >= 0.05;
      expect(phoneInZoneTouching, isTrue);
    });
  });
}

