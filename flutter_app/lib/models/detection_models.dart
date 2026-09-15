import 'dart:ui';

/// Bounding box cho bàn tay hoặc điện thoại
class DetectionBox {
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final double confidence;
  final String label;
  final bool isInsideZone;
  /// 21 điểm đốt ngón tay MediaPipe (pixel coords gốc), null nếu không có
  final List<Offset>? landmarks;

  const DetectionBox({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.confidence,
    required this.label,
    this.isInsideZone = false,
    this.landmarks,
  });

  factory DetectionBox.fromList(List<dynamic> list, String defaultLabel) {
    // Format: [x1, y1, x2, y2] hoặc [x1, y1, x2, y2, confidence]
    final x1 = (list[0] as num).toDouble();
    final y1 = (list[1] as num).toDouble();
    final x2 = (list[2] as num).toDouble();
    final y2 = (list[3] as num).toDouble();
    final conf = list.length > 4 ? (list[4] as num).toDouble() : 1.0;
    return DetectionBox(
      x1: x1,
      y1: y1,
      x2: x2,
      y2: y2,
      confidence: conf,
      label: defaultLabel,
    );
  }

  Rect toRect() => Rect.fromLTRB(x1, y1, x2, y2);
}

/// Kết quả phản hồi từ AI Backend
class DetectFrameResponse {
  final bool success;
  final bool triggerAlarm;
  final bool alarmInstant;
  final bool holdingPhone;
  final bool inWarningZone;
  final int handsCount;
  final int phonesCount;
  final double overlapRatio;
  final double processTimeMs;
  final double remainingDelay;
  final String? deviceInfo;
  final String? base64Image;
  final double imageWidth;
  final double imageHeight;
  final List<DetectionBox> hands;
  final List<DetectionBox> phones;

  const DetectFrameResponse({
    required this.success,
    required this.triggerAlarm,
    required this.alarmInstant,
    required this.holdingPhone,
    required this.inWarningZone,
    required this.handsCount,
    required this.phonesCount,
    required this.overlapRatio,
    required this.processTimeMs,
    required this.remainingDelay,
    this.deviceInfo,
    this.base64Image,
    this.imageWidth = 640.0,
    this.imageHeight = 480.0,
    required this.hands,
    required this.phones,
  });

  factory DetectFrameResponse.fromJson(Map<String, dynamic> json) {
    final rawHands = json['hands'] as List<dynamic>? ?? [];
    final rawPhones = json['phones'] as List<dynamic>? ?? [];

    return DetectFrameResponse(
      success: json['success'] as bool? ?? false,
      triggerAlarm: json['trigger_alarm'] as bool? ?? false,
      alarmInstant: json['alarm_instant'] as bool? ?? false,
      holdingPhone: json['holding_phone'] as bool? ?? false,
      inWarningZone: json['in_warning_zone'] as bool? ?? false,
      handsCount: json['hands_count'] as int? ?? 0,
      phonesCount: json['phones_count'] as int? ?? 0,
      overlapRatio: (json['overlap_ratio'] as num?)?.toDouble() ?? 0.0,
      processTimeMs: (json['process_time_ms'] as num?)?.toDouble() ?? 0.0,
      remainingDelay: (json['remaining_delay'] as num?)?.toDouble() ?? 0.0,
      deviceInfo: json['device_info'] as String?,
      base64Image: json['image'] as String?,
      hands: rawHands.map((h) => DetectionBox.fromList(h as List<dynamic>, 'Vùng tay')).toList(),
      phones: rawPhones.map((p) => DetectionBox.fromList(p as List<dynamic>, 'Điện thoại')).toList(),
    );
  }
}
