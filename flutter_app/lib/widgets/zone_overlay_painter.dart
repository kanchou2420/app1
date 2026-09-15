import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/detection_models.dart';

class ZoneOverlayPainter extends CustomPainter {
  final Rect warningZoneNormalized; // [0.0 - 1.0] relative to destinationRect
  final bool isDrawing;
  final bool isAlarm;
  final bool isMirrored;
  final List<DetectionBox> hands;
  final List<DetectionBox> phones;
  final Size? originalImageSize;
  final Rect? destinationRect; // Vùng hiển thị thực tế của video/ảnh trong viewport

  const ZoneOverlayPainter({
    required this.warningZoneNormalized,
    required this.isDrawing,
    required this.isAlarm,
    required this.isMirrored,
    required this.hands,
    required this.phones,
    this.originalImageSize,
    this.destinationRect,
  });

  // MediaPipe Hand Connections: 20 đường nối giữa 21 khớp
  static const List<List<int>> _handConnections = [
    // Ngón cái (Thumb)
    [0, 1], [1, 2], [2, 3], [3, 4],
    // Ngón trỏ (Index)
    [0, 5], [5, 6], [6, 7], [7, 8],
    // Ngón giữa (Middle)
    [0, 9], [9, 10], [10, 11], [11, 12],
    // Ngón áp út (Ring)
    [0, 13], [13, 14], [14, 15], [15, 16],
    // Ngón út (Pinky)
    [0, 17], [17, 18], [18, 19], [19, 20],
    // Nối ngang gốc các ngón (Palm)
    [5, 9], [9, 13], [13, 17],
  ];

  // Màu cho từng nhóm khớp (5 ngón + cổ tay)
  static const List<Color> _fingerColors = [
    Color(0xFFFF6B6B), // Thumb - Đỏ san hô
    Color(0xFF4ECDC4), // Index - Xanh ngọc
    Color(0xFF45B7D1), // Middle - Xanh dương
    Color(0xFFFFA07A), // Ring - Cam nhạt
    Color(0xFFDDA0DD), // Pinky - Tím nhạt
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    // Xác định vùng hiển thị thực tế (bỏ qua viền đen letterbox/pillarbox)
    final renderRect = destinationRect ?? Rect.fromLTWH(0, 0, w, h);
    if (renderRect.width <= 0 || renderRect.height <= 0) return;

    // 1. Tọa độ Vùng Cảnh Báo theo pixel của vùng hiển thị thực tế
    final zx1 = renderRect.left + warningZoneNormalized.left * renderRect.width;
    final zy1 = renderRect.top + warningZoneNormalized.top * renderRect.height;
    final zx2 = renderRect.left + warningZoneNormalized.right * renderRect.width;
    final zy2 = renderRect.top + warningZoneNormalized.bottom * renderRect.height;
    final zoneRect = Rect.fromLTRB(
      math.min(zx1, zx2),
      math.min(zy1, zy2),
      math.max(zx1, zx2),
      math.max(zy1, zy2),
    );

    final Paint borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = isDrawing ? 2.5 : (isAlarm ? 3.0 : 2.0);

    Color themeColor;
    String zoneLabel;

    if (isDrawing) {
      themeColor = const Color(0xFF38BDF8); // Cyan sáng
      final pctW = ((zoneRect.width / renderRect.width) * 100).round();
      final pctH = ((zoneRect.height / renderRect.height) * 100).round();
      zoneLabel = 'ĐANG VẼ VÙNG: $pctW% x $pctH%';
    } else if (isAlarm) {
      themeColor = const Color(0xFFEF4444); // Đỏ cảnh báo
      zoneLabel = 'VÙNG GIÁM SÁT [BỊ XÂM PHẠM BỞI ĐIỆN THOẠI!]';
    } else {
      themeColor = const Color(0xFF06B6D4); // Cyan an toàn
      zoneLabel = 'VÙNG GIÁM SÁT [AN TOÀN - CHƯA CÓ XÂM PHẠM]';
    }

    borderPaint.color = themeColor;

    // Vẽ khung viền nét đứt (Dashed Rectangle)
    _drawDashedRect(canvas, zoneRect, borderPaint, dashWidth: 8, dashSpace: 5);

    // Vẽ 4 góc định vị công nghệ cao
    _drawCornerBrackets(canvas, zoneRect, themeColor, cornerLen: 16, strokeWidth: 3.0);

    // Nhãn tiêu đề Vùng Cảnh Báo
    final textSpan = TextSpan(
      text: zoneLabel,
      style: TextStyle(
        color: themeColor,
        fontSize: 13,
        fontWeight: FontWeight.bold,
        backgroundColor: Colors.black.withValues(alpha: 0.6),
      ),
    );
    final textPainter = TextPainter(text: textSpan, textDirection: TextDirection.ltr);
    textPainter.layout();
    textPainter.paint(canvas, Offset(zoneRect.left + 8, (zoneRect.top - 20).clamp(renderRect.top + 4.0, renderRect.bottom - 24)));

    // 2. Vẽ các bounding boxes của Bàn tay & Điện thoại
    if (originalImageSize != null && originalImageSize!.width > 0 && originalImageSize!.height > 0) {
      final scaleX = renderRect.width / originalImageSize!.width;
      final scaleY = renderRect.height / originalImageSize!.height;

      // Vẽ bàn tay
      for (int i = 0; i < hands.length; i++) {
        final hand = hands[i];
        double hx1 = renderRect.left + hand.x1 * scaleX;
        double hy1 = renderRect.top + hand.y1 * scaleY;
        double hx2 = renderRect.left + hand.x2 * scaleX;
        double hy2 = renderRect.top + hand.y2 * scaleY;

        if (isMirrored) {
          final t1 = renderRect.left + renderRect.width - (hx2 - renderRect.left);
          final t2 = renderRect.left + renderRect.width - (hx1 - renderRect.left);
          hx1 = t1;
          hx2 = t2;
        }

        final handRect = Rect.fromLTRB(
          math.min(hx1, hx2),
          math.min(hy1, hy2),
          math.max(hx1, hx2),
          math.max(hy1, hy2),
        );
        final isHandViolating = hand.isInsideZone;
        final handColor = isHandViolating ? const Color(0xFFEF4444) : const Color(0xFFF59E0B);
        final handPaint = Paint()
          ..color = handColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = isHandViolating ? 3.0 : 2.0;

        canvas.drawRect(handRect, handPaint);

        // Vẽ skeleton 21 khớp tay nếu có landmarks
        if (hand.landmarks != null && hand.landmarks!.length >= 21) {
          _drawHandSkeleton(canvas, hand.landmarks!, scaleX, scaleY, renderRect, isHandViolating);
        }

        final labelSpan = TextSpan(
          text: '${hand.label} ${(hand.confidence * 100).toStringAsFixed(0)}%',
          style: TextStyle(
            color: handColor,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            backgroundColor: Colors.black.withValues(alpha: 0.75),
          ),
        );
        final lp = TextPainter(text: labelSpan, textDirection: TextDirection.ltr);
        lp.layout();
        lp.paint(canvas, Offset(handRect.left + 4, (handRect.top - 18).clamp(renderRect.top + 4.0, renderRect.bottom - 20)));
      }

      // Vẽ điện thoại
      for (final phone in phones) {
        double px1 = renderRect.left + phone.x1 * scaleX;
        double py1 = renderRect.top + phone.y1 * scaleY;
        double px2 = renderRect.left + phone.x2 * scaleX;
        double py2 = renderRect.top + phone.y2 * scaleY;

        if (isMirrored) {
          final t1 = renderRect.left + renderRect.width - (px2 - renderRect.left);
          final t2 = renderRect.left + renderRect.width - (px1 - renderRect.left);
          px1 = t1;
          px2 = t2;
        }

        final phoneRect = Rect.fromLTRB(
          math.min(px1, px2),
          math.min(py1, py2),
          math.max(px1, px2),
          math.max(py1, py2),
        );
        final isPhoneViolating = phone.isInsideZone;
        final phoneColor = isPhoneViolating ? const Color(0xFFEF4444) : const Color(0xFF38BDF8);
        final phonePaint = Paint()
          ..color = phoneColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = isPhoneViolating ? 3.0 : 2.0;

        canvas.drawRect(phoneRect, phonePaint);

        final phoneLabelSpan = TextSpan(
          text: '${phone.label} ${(phone.confidence * 100).toStringAsFixed(0)}%',
          style: TextStyle(
            color: phoneColor,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            backgroundColor: Colors.black.withValues(alpha: 0.75),
          ),
        );
        final pp = TextPainter(text: phoneLabelSpan, textDirection: TextDirection.ltr);
        pp.layout();
        pp.paint(canvas, Offset(phoneRect.left + 4, (phoneRect.top - 18).clamp(renderRect.top + 4.0, renderRect.bottom - 20)));
      }
    }
  }

  /// Vẽ skeleton 21 khớp tay MediaPipe
  void _drawHandSkeleton(Canvas canvas, List<Offset> landmarks, double scaleX, double scaleY, Rect renderRect, bool isViolating) {
    // Chuyển 21 điểm từ tọa độ pixel gốc sang tọa độ viewport
    final pts = <Offset>[];
    for (int i = 0; i < landmarks.length && i < 21; i++) {
      double px = renderRect.left + landmarks[i].dx * scaleX;
      double py = renderRect.top + landmarks[i].dy * scaleY;
      if (isMirrored) {
        px = renderRect.left + renderRect.width - (px - renderRect.left);
      }
      pts.add(Offset(px, py));
    }
    if (pts.length < 21) return;

    // Vẽ 23 đường nối (bones) giữa các khớp
    final bonePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    for (int c = 0; c < _handConnections.length; c++) {
      final from = _handConnections[c][0];
      final to = _handConnections[c][1];
      if (from >= pts.length || to >= pts.length) continue;

      // Chọn màu theo nhóm ngón
      Color boneColor;
      if (c < 4) {
        boneColor = _fingerColors[0]; // Thumb
      } else if (c < 8) {
        boneColor = _fingerColors[1]; // Index
      } else if (c < 12) {
        boneColor = _fingerColors[2]; // Middle
      } else if (c < 16) {
        boneColor = _fingerColors[3]; // Ring
      } else if (c < 20) {
        boneColor = _fingerColors[4]; // Pinky
      } else {
        boneColor = const Color(0xFFE2E8F0); // Palm connections
      }

      if (isViolating) {
        boneColor = const Color(0xFFFF6B6B);
      }

      bonePaint.color = boneColor.withValues(alpha: 0.85);
      canvas.drawLine(pts[from], pts[to], bonePaint);
    }

    // Vẽ 21 điểm khớp (joints)
    final jointPaint = Paint()..style = PaintingStyle.fill;
    final jointBorderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Colors.black.withValues(alpha: 0.7);

    for (int i = 0; i < 21; i++) {
      // Chọn màu theo nhóm ngón
      Color jointColor;
      if (i == 0) {
        jointColor = Colors.white; // Wrist
      } else if (i <= 4) {
        jointColor = _fingerColors[0]; // Thumb
      } else if (i <= 8) {
        jointColor = _fingerColors[1]; // Index
      } else if (i <= 12) {
        jointColor = _fingerColors[2]; // Middle
      } else if (i <= 16) {
        jointColor = _fingerColors[3]; // Ring
      } else {
        jointColor = _fingerColors[4]; // Pinky
      }

      if (isViolating) {
        jointColor = const Color(0xFFFF6B6B);
      }

      // Đầu ngón tay (tip) vẽ to hơn
      final isTip = (i == 4 || i == 8 || i == 12 || i == 16 || i == 20);
      final radius = isTip ? 5.0 : 3.5;

      jointPaint.color = jointColor;
      canvas.drawCircle(pts[i], radius, jointPaint);
      canvas.drawCircle(pts[i], radius, jointBorderPaint);
    }
  }

  void _drawDashedRect(Canvas canvas, Rect rect, Paint paint, {double dashWidth = 8, double dashSpace = 5}) {
    final path = Path();
    // Top
    _addDashedLine(path, Offset(rect.left, rect.top), Offset(rect.right, rect.top), dashWidth, dashSpace);
    // Right
    _addDashedLine(path, Offset(rect.right, rect.top), Offset(rect.right, rect.bottom), dashWidth, dashSpace);
    // Bottom
    _addDashedLine(path, Offset(rect.right, rect.bottom), Offset(rect.left, rect.bottom), dashWidth, dashSpace);
    // Left
    _addDashedLine(path, Offset(rect.left, rect.bottom), Offset(rect.left, rect.top), dashWidth, dashSpace);

    canvas.drawPath(path, paint);
  }

  void _addDashedLine(Path path, Offset start, Offset end, double dashWidth, double dashSpace) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final distance = (dx * dx + dy * dy);
    final totalLen = math.sqrt(distance);
    if (totalLen <= 0) return;

    final unitX = dx / totalLen;
    final unitY = dy / totalLen;

    double current = 0;
    while (current < totalLen) {
      final len = math.min(dashWidth, totalLen - current);
      path.moveTo(start.dx + unitX * current, start.dy + unitY * current);
      path.lineTo(start.dx + unitX * (current + len), start.dy + unitY * (current + len));
      current += dashWidth + dashSpace;
    }
  }

  void _drawCornerBrackets(Canvas canvas, Rect r, Color color, {double cornerLen = 14, double strokeWidth = 3}) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    // Top-left
    canvas.drawLine(Offset(r.left, r.top + cornerLen), Offset(r.left, r.top), p);
    canvas.drawLine(Offset(r.left, r.top), Offset(r.left + cornerLen, r.top), p);

    // Top-right
    canvas.drawLine(Offset(r.right - cornerLen, r.top), Offset(r.right, r.top), p);
    canvas.drawLine(Offset(r.right, r.top), Offset(r.right, r.top + cornerLen), p);

    // Bottom-left
    canvas.drawLine(Offset(r.left, r.bottom - cornerLen), Offset(r.left, r.bottom), p);
    canvas.drawLine(Offset(r.left, r.bottom), Offset(r.left + cornerLen, r.bottom), p);

    // Bottom-right
    canvas.drawLine(Offset(r.right - cornerLen, r.bottom), Offset(r.right, r.bottom), p);
    canvas.drawLine(Offset(r.right, r.bottom), Offset(r.right, r.bottom - cornerLen), p);
  }

  @override
  bool shouldRepaint(covariant ZoneOverlayPainter oldDelegate) => true;
}
