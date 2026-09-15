import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import '../models/detection_models.dart';

class OnDeviceDetectorService {
  static final OnDeviceDetectorService _instance = OnDeviceDetectorService._internal();
  factory OnDeviceDetectorService() => _instance;
  OnDeviceDetectorService._internal();

  OrtSession? _phoneSession;
  OrtSession? _handPalmSession;
  OrtSession? _handLandmarksSession;
  Float32List? _handAnchors; // 2016 * 4 values

  // Reusable static buffers (Zero-allocation loop to eliminate GC pauses on Intel N97 / low-power chips)
  static const int _phoneTargetSize = 512;
  static const int _palmTargetSize = 192;
  static const int _lmTargetSize = 224;

  final Float32List _phoneInputBuffer = Float32List(1 * 3 * _phoneTargetSize * _phoneTargetSize);
  final Float32List _palmInputBuffer = Float32List(1 * _palmTargetSize * _palmTargetSize * 3);
  final Float32List _landmarkInputBuffer = Float32List(1 * _lmTargetSize * _lmTargetSize * 3);

  bool _isInitialized = false;
  bool _isInitializing = false;
  String _initStatus = 'Chưa nạp mô hình';
  String _activeEngine = 'CPU';

  bool get isInitialized => _isInitialized;
  String get initStatus => _initStatus;
  String get activeEngine => _activeEngine;

  /// Khởi tạo môi trường ONNX Runtime & nạp trọng số mô hình:
  /// Tối ưu đặc biệt cho Intel Processor N97 (4 Gracemont Cores, AVX2, VNNI)
  Future<bool> initialize({int? threadCount}) async {
    if (_isInitialized) return true;
    if (_isInitializing) return false;

    _isInitializing = true;
    _initStatus = 'Đang khởi tạo ONNX Runtime Engine...';

    try {
      // 1. Khởi tạo môi trường OnnxRuntime FFI
      OrtEnv.instance.init();

      // 2. Cấu hình Session Options tối ưu đa luồng CPU cho Intel N97
      final sessionOptions = OrtSessionOptions();
      // Intel N97 có 4 physical cores -> Cấu hình 4 luồng intra-op tối ưu vector hóa AVX2
      final threads = threadCount ?? math.max(1, Platform.numberOfProcessors);
      sessionOptions.setIntraOpNumThreads(threads);
      // Giữ inter-op = 1 trên 4 core để tránh cache thrashing L3 (N97 có 6MB cache)
      sessionOptions.setInterOpNumThreads(1);

      _activeEngine = 'Intel N97 AVX2 Native ($threads Threads)';

      // 3. Nạp model Điện Thoại (phone_detect_weights.onnx)
      Uint8List? phoneModelBytes = await _loadModelBytes('assets/models/phone_detect_weights.onnx', [
        'assets/models/phone_detect_weights.onnx',
        'phone_detect_weights.onnx',
      ]);

      if (phoneModelBytes != null && phoneModelBytes.isNotEmpty) {
        _phoneSession = OrtSession.fromBuffer(phoneModelBytes, sessionOptions);
      } else {
        _initStatus = 'Lỗi: Không tìm thấy phone_detect_weights.onnx';
        _isInitializing = false;
        return false;
      }

      // 4. Nạp model Bàn Tay Stage 1: Palm Detector (hand_detector.onnx)
      Uint8List? palmModelBytes = await _loadModelBytes('assets/models/hand_detector.onnx', [
        'assets/models/hand_detector.onnx',
        'hand_detector.onnx',
      ]);

      if (palmModelBytes != null && palmModelBytes.isNotEmpty) {
        _handPalmSession = OrtSession.fromBuffer(palmModelBytes, sessionOptions);
      }

      // 5. Nạp model Bàn Tay Stage 2: 21 Finger Landmarks (hand_landmarks_detector.onnx)
      Uint8List? landmarksModelBytes = await _loadModelBytes('assets/models/hand_landmarks_detector.onnx', [
        'assets/models/hand_landmarks_detector.onnx',
        'hand_landmarks_detector.onnx',
      ]);

      if (landmarksModelBytes != null && landmarksModelBytes.isNotEmpty) {
        _handLandmarksSession = OrtSession.fromBuffer(landmarksModelBytes, sessionOptions);
      }

      // 6. Nạp Hand Anchors (2016 anchors x 4)
      await _loadHandAnchors();

      _isInitialized = true;
      _isInitializing = false;
      _initStatus = 'Sẵn sàng: Nhận diện Điện thoại & 21 Đốt Ngón Tay ($_activeEngine)';
      return true;
    } catch (e) {
      _initStatus = 'Lỗi khởi tạo ONNX Session: $e';
      _isInitializing = false;
      return false;
    }
  }

  Future<Uint8List?> _loadModelBytes(String assetPath, List<String> fileFallbacks) async {
    try {
      final assetData = await rootBundle.load(assetPath);
      return assetData.buffer.asUint8List();
    } catch (_) {
      for (final p in fileFallbacks) {
        final f = File(p);
        if (await f.exists()) {
          return await f.readAsBytes();
        }
      }
    }
    return null;
  }

  Future<void> _loadHandAnchors() async {
    try {
      String csvText = '';
      try {
        csvText = await rootBundle.loadString('assets/models/hand_anchors.csv');
      } catch (_) {
        final f = File('assets/models/hand_anchors.csv');
        if (await f.exists()) {
          csvText = await f.readAsString();
        }
      }

      if (csvText.isNotEmpty) {
        final lines = csvText.trim().split('\n');
        final list = Float32List(lines.length * 4);
        int ptr = 0;
        for (final line in lines) {
          final parts = line.trim().split(',');
          if (parts.length >= 4) {
            list[ptr++] = double.tryParse(parts[0]) ?? 0.0;
            list[ptr++] = double.tryParse(parts[1]) ?? 0.0;
            list[ptr++] = double.tryParse(parts[2]) ?? 1.0;
            list[ptr++] = double.tryParse(parts[3]) ?? 1.0;
          }
        }
        _handAnchors = list;
      }
    } catch (_) {}
  }

  /// Suy luận song song Điện Thoại & Bàn Tay với logic Zone chuẩn xác tuyệt đối
  Future<DetectFrameResponse?> detectFrame({
    required Uint8List imageBytes,
    required Rect warningZone,
    double phoneThreshold = 0.68,
    double handThreshold = 0.60,
  }) async {
    if (!_isInitialized || _phoneSession == null) {
      final ok = await initialize();
      if (!ok || _phoneSession == null) return null;
    }

    final stopwatch = Stopwatch()..start();

    try {
      // 1. Giải mã khung hình
      final decodedImage = img.decodeImage(imageBytes);
      if (decodedImage == null) return null;

      final origW = decodedImage.width.toDouble();
      final origH = decodedImage.height.toDouble();

      final List<DetectionBox> detectedPhones = [];
      final List<DetectionBox> detectedHands = [];

      // =========================================================
      // A. NHẬN DIỆN ĐIỆN THOẠI (RF-DETR 512x512)
      // =========================================================
      await _detectPhones(
        image: decodedImage,
        origW: origW,
        origH: origH,
        threshold: phoneThreshold,
        outPhones: detectedPhones,
      );

      // =========================================================
      // B. NHẬN DIỆN BÀN TAY (MediaPipe Two-Stage: Palm + 21 Finger Landmarks)
      // =========================================================
      if (_handPalmSession != null && _handAnchors != null) {
        await _detectHandsTwoStage(
          image: decodedImage,
          origW: origW,
          origH: origH,
          threshold: handThreshold,
          outHands: detectedHands,
        );
      }

      // =========================================================
      // C. PHÂN ĐỊNH XÂM PHẠM ZONE CHUẨN XÁC 100%:
      //    1. Vật thể ở ngoài zone -> AN TOÀN (Box xanh/vàng, KHÔNG BÁO ĐỘNG).
      //    2. Chỉ khi TAY CẦM ĐIỆN THOẠI THỰC SỰ ĐI VÀO TRONG ZONE:
      //       - Tâm điện thoại nằm trong Zone, HOẶC
      //       - Tối thiểu 30% diện tích điện thoại đã lọt vào trong Zone.
      //       -> MỚI KÍCH HOẠT BÁO ĐỘNG (triggerAlarm = true)!
      // =========================================================
      final List<DetectionBox> finalPhones = [];
      final List<DetectionBox> finalHands = [];

      bool holdingPhone = false;
      bool inWarningZone = false;
      double maxOverlap = 0.0;

      for (final phone in detectedPhones) {
        // Tọa độ tâm (Center) điện thoại theo hệ chuẩn hóa [0.0 - 1.0]
        final pcx = (phone.x1 + phone.x2) / (2.0 * origW);
        final pcy = (phone.y1 + phone.y2) / (2.0 * origH);
        final pCenter = Offset(pcx, pcy);

        // Tính tỷ lệ diện tích điện thoại nằm trong Vùng Cảnh Báo
        final normPhoneRect = Rect.fromLTRB(
          phone.x1 / origW,
          phone.y1 / origH,
          phone.x2 / origW,
          phone.y2 / origH,
        );
        final inter = warningZone.intersect(normPhoneRect);
        double phoneOverlapZoneRatio = 0.0;
        if (inter.width > 0 && inter.height > 0) {
          final phoneArea = normPhoneRect.width * normPhoneRect.height;
          phoneOverlapZoneRatio = phoneArea > 0 ? (inter.width * inter.height) / phoneArea : 0.0;
        }

        // ĐIỀU KIỆN ĐỘ NHẠY CAO THEO YÊU CẦU:
        // Chỉ cần hơi chạm 5% - 10% diện tích hoặc tâm lọt vào trong Zone là lập tức tính là xâm phạm!
        final bool isPhoneInZone = warningZone.contains(pCenter) ||
            (inter.width > 0 && inter.height > 0 && phoneOverlapZoneRatio >= 0.05);

        // Kiểm tra xem điện thoại này có đang được bàn tay nào cầm không
        bool isThisPhoneHeld = false;
        bool isHoldingHandInZone = false;
        for (final hand in detectedHands) {
          final ox1 = math.max(hand.x1, phone.x1);
          final oy1 = math.max(hand.y1, phone.y1);
          final ox2 = math.min(hand.x2, phone.x2);
          final oy2 = math.min(hand.y2, phone.y2);

          if (ox2 > ox1 && oy2 > oy1) {
            final overlapArea = (ox2 - ox1) * (oy2 - oy1);
            final phoneArea = math.max(1.0, (phone.x2 - phone.x1) * (phone.y2 - phone.y1));
            final ratio = overlapArea / phoneArea;

            // Độ nhạy cầm điện thoại cao: từ 10% hoặc 150 pixels
            if (ratio >= 0.10 || overlapArea >= 150.0) {
              isThisPhoneHeld = true;
              maxOverlap = math.max(maxOverlap, ratio);

              // Bàn tay cầm điện thoại chạm vào zone (>= 5%)
              final normHandRect = Rect.fromLTRB(
                hand.x1 / origW,
                hand.y1 / origH,
                hand.x2 / origW,
                hand.y2 / origH,
              );
              final handInter = warningZone.intersect(normHandRect);
              final hcx = (hand.x1 + hand.x2) / (2.0 * origW);
              final hcy = (hand.y1 + hand.y2) / (2.0 * origH);
              if (warningZone.contains(Offset(hcx, hcy)) ||
                  (handInter.width > 0 && handInter.height > 0 &&
                      (handInter.width * handInter.height) / (normHandRect.width * normHandRect.height) >= 0.05)) {
                isHoldingHandInZone = true;
              }
              break;
            }
          }
        }

        if (isThisPhoneHeld) {
          holdingPhone = true;
          // Cảnh báo ngay khi điện thoại chạm vào zone (>= 5%) HOẶC tay cầm điện thoại chạm vào zone (>= 5%)
          if (isPhoneInZone || isHoldingHandInZone) {
            inWarningZone = true;
          }
        }

        finalPhones.add(DetectionBox(
          x1: phone.x1,
          y1: phone.y1,
          x2: phone.x2,
          y2: phone.y2,
          confidence: phone.confidence,
          label: isPhoneInZone
              ? (isThisPhoneHeld ? 'ĐIỆN THOẠI [XÂM PHẠM ZONE]' : 'Điện thoại [Trong zone]')
              : 'Điện thoại (Ngoài zone)',
          isInsideZone: isPhoneInZone,
        ));
      }

      // Xử lý nhãn cho bàn tay
      for (final hand in detectedHands) {
        final hcx = (hand.x1 + hand.x2) / (2.0 * origW);
        final hcy = (hand.y1 + hand.y2) / (2.0 * origH);
        final normHandRect = Rect.fromLTRB(
          hand.x1 / origW,
          hand.y1 / origH,
          hand.x2 / origW,
          hand.y2 / origH,
        );
        final handInter = warningZone.intersect(normHandRect);
        final isHandInZone = warningZone.contains(Offset(hcx, hcy)) ||
            (handInter.width > 0 && handInter.height > 0 &&
                (handInter.width * handInter.height) / (normHandRect.width * normHandRect.height) >= 0.05);

        finalHands.add(DetectionBox(
          x1: hand.x1,
          y1: hand.y1,
          x2: hand.x2,
          y2: hand.y2,
          confidence: hand.confidence,
          label: (inWarningZone && isHandInZone)
              ? 'Bàn tay [Cầm ĐT xâm phạm]'
              : 'Bàn tay',
          isInsideZone: inWarningZone && isHandInZone,
          landmarks: hand.landmarks,
        ));
      }

      // 3. ĐIỀU KIỆN KÍCH HOẠT CẢNH BÁO:
      // CHỈ CẢNH BÁO KHI TAY CẦM ĐIỆN THOẠI THỰC SỰ XÂM PHẠM VÀO BÊN TRONG VÙNG CẢNH BÁO!
      final triggerAlarm = holdingPhone && inWarningZone;

      stopwatch.stop();

      return DetectFrameResponse(
        success: true,
        triggerAlarm: triggerAlarm,
        alarmInstant: triggerAlarm,
        holdingPhone: holdingPhone,
        inWarningZone: inWarningZone,
        handsCount: finalHands.length,
        phonesCount: finalPhones.length,
        overlapRatio: maxOverlap,
        processTimeMs: stopwatch.elapsedMilliseconds.toDouble(),
        remainingDelay: triggerAlarm ? 3.0 : 0.0,
        deviceInfo: _activeEngine,
        imageWidth: origW,
        imageHeight: origH,
        hands: finalHands,
        phones: finalPhones,
      );
    } catch (_) {
      stopwatch.stop();
      return null;
    }
  }

  /// Xử lý nhận diện điện thoại với Stretch to 512x512 chuẩn Roboflow RF-DETR & NMS
  Future<void> _detectPhones({
    required img.Image image,
    required double origW,
    required double origH,
    required double threshold,
    required List<DetectionBox> outPhones,
  }) async {
    const targetSize = _phoneTargetSize;

    // ===== STRETCH TO 512x512: Chuẩn tiền xử lý Roboflow RF-DETR gốc =====
    final resized = img.copyResize(
      image,
      width: targetSize,
      height: targetSize,
      interpolation: img.Interpolation.linear,
    );

    // Chuẩn hóa ImageNet trực tiếp qua mảng byte (1 pass siêu nhanh)
    const meanR = 0.485, meanG = 0.456, meanB = 0.406;
    const stdR = 0.229, stdG = 0.224, stdB = 0.225;

    final resizedBytes = resized.buffer.asUint8List();
    final hasAlpha = resized.numChannels == 4;
    final step = hasAlpha ? 4 : 3;
    final channelStride = targetSize * targetSize;

    int srcIdx = 0;
    for (int i = 0; i < channelStride; i++) {
      _phoneInputBuffer[i] = ((resizedBytes[srcIdx] / 255.0) - meanR) / stdR;
      _phoneInputBuffer[channelStride + i] = ((resizedBytes[srcIdx + 1] / 255.0) - meanG) / stdG;
      _phoneInputBuffer[channelStride * 2 + i] = ((resizedBytes[srcIdx + 2] / 255.0) - meanB) / stdB;
      srcIdx += step;
    }

    final inputTensor = OrtValueTensor.createTensorWithDataList(
      _phoneInputBuffer,
      [1, 3, targetSize, targetSize],
    );

    final runOptions = OrtRunOptions();
    final outputs = await _phoneSession!.runAsync(runOptions, {'input': inputTensor});
    inputTensor.release();
    runOptions.release();

    if (outputs == null || outputs.isEmpty) return;

    List<dynamic>? rawDets;
    List<dynamic>? rawLabels;

    for (final out in outputs) {
      if (out != null) {
        final val = out.value;
        if (val is List && val.isNotEmpty && val[0] is List) {
          final firstRow = (val[0] as List);
          if (firstRow.isNotEmpty && firstRow[0] is List) {
            final len = (firstRow[0] as List).length;
            if (len == 4) {
              rawDets = val[0] as List<dynamic>; // [300, 4]
            } else if (len == 3 || len == 80) {
              rawLabels = val[0] as List<dynamic>; // [300, 3]
            }
          }
        }
      }
    }

    for (final out in outputs) {
      out?.release();
    }

    if (rawDets != null && rawLabels != null) {
      final candidates = <DetectionBox>[];
      final count = math.min(rawDets.length, rawLabels.length);

      for (int i = 0; i < count; i++) {
        final det = rawDets[i] as List<dynamic>;
        final labelScores = rawLabels[i] as List<dynamic>;

        if (det.length < 4 || labelScores.length < 2) continue;

        // Class 1 là Điện thoại trong model RF-DETR
        final logit = (labelScores[1] as num).toDouble();
        final prob = 1.0 / (1.0 + math.exp(-logit));

        if (prob >= threshold) {
          final cx = (det[0] as num).toDouble();
          final cy = (det[1] as num).toDouble();
          final w = (det[2] as num).toDouble();
          final h = (det[3] as num).toDouble();

          // Chuyển từ normalized [0,1] sang tọa độ pixel ảnh gốc chuẩn RF-DETR Stretch to
          final x1 = math.max(0.0, (cx - w / 2.0) * origW);
          final y1 = math.max(0.0, (cy - h / 2.0) * origH);
          final x2 = math.min(origW, (cx + w / 2.0) * origW);
          final y2 = math.min(origH, (cy + h / 2.0) * origH);

          if (x2 > x1 && y2 > y1) {
            candidates.add(DetectionBox(
              x1: x1,
              y1: y1,
              x2: x2,
              y2: y2,
              confidence: prob,
              label: 'Điện thoại',
            ));
          }
        }
      }

      // NMS loại bỏ các box trùng lặp trên cùng một điện thoại
      _applyNms(candidates, outPhones, iouThreshold: 0.35);
    }
  }

  /// Nhận diện bàn tay 2 giai đoạn (MediaPipe Two-Stage Pipeline chuẩn)
  Future<void> _detectHandsTwoStage({
    required img.Image image,
    required double origW,
    required double origH,
    required double threshold,
    required List<DetectionBox> outHands,
  }) async {
    const palmSize = _palmTargetSize;
    final resizedPalm = img.copyResize(
      image,
      width: palmSize,
      height: palmSize,
      interpolation: img.Interpolation.linear,
    );

    // Giai đoạn 1: Palm Detector [1, 192, 192, 3] trong dải [0.0, 1.0] (HWC layout)
    final palmBytes = resizedPalm.buffer.asUint8List();
    final hasAlpha = resizedPalm.numChannels == 4;
    final step = hasAlpha ? 4 : 3;
    final numPixels = palmSize * palmSize;

    int pIdx = 0;
    int srcIdx = 0;
    for (int i = 0; i < numPixels; i++) {
      _palmInputBuffer[pIdx++] = palmBytes[srcIdx] / 255.0;
      _palmInputBuffer[pIdx++] = palmBytes[srcIdx + 1] / 255.0;
      _palmInputBuffer[pIdx++] = palmBytes[srcIdx + 2] / 255.0;
      srcIdx += step;
    }

    final palmTensor = OrtValueTensor.createTensorWithDataList(
      _palmInputBuffer,
      [1, palmSize, palmSize, 3],
    );

    final palmRunOptions = OrtRunOptions();
    final palmOutputs = await _handPalmSession!.runAsync(palmRunOptions, {'input_1': palmTensor});
    palmTensor.release();
    palmRunOptions.release();

    if (palmOutputs == null || palmOutputs.isEmpty) return;

    List<dynamic>? rawBoxes;
    List<dynamic>? rawScores;

    for (final out in palmOutputs) {
      if (out != null) {
        final val = out.value;
        if (val is List && val.isNotEmpty && val[0] is List) {
          final firstRow = (val[0] as List);
          if (firstRow.isNotEmpty && firstRow[0] is List) {
            final len = (firstRow[0] as List).length;
            if (len == 18) {
              rawBoxes = val[0] as List<dynamic>; // [2016, 18]
            } else if (len == 1) {
              rawScores = val[0] as List<dynamic>; // [2016, 1]
            }
          }
        }
      }
    }

    for (final out in palmOutputs) {
      out?.release();
    }

    if (rawBoxes == null || rawScores == null || _handAnchors == null) return;

    final candidates = <DetectionBox>[];
    final count = math.min(rawBoxes.length, rawScores.length);
    final totalAnchors = _handAnchors!.length ~/ 4;
    final limit = math.min(count, totalAnchors);

    // Thu thập các ứng viên bàn tay từ Palm Detector với Vector Shift chuẩn MediaPipe
    for (int i = 0; i < limit; i++) {
      final scoreRow = rawScores[i] as List<dynamic>;
      if (scoreRow.isEmpty) continue;

      final rawScore = (scoreRow[0] as num).toDouble();
      final prob = 1.0 / (1.0 + math.exp(-rawScore));

      if (prob >= threshold) {
        final boxRow = rawBoxes[i] as List<dynamic>;
        if (boxRow.length < 10) continue;

        final ax = _handAnchors![i * 4 + 0];
        final ay = _handAnchors![i * 4 + 1];
        final dx = (boxRow[0] as num).toDouble();
        final dy = (boxRow[1] as num).toDouble();
        final dw = (boxRow[2] as num).toDouble();
        final dh = (boxRow[3] as num).toDouble();

        // Keypoint 0 (Cổ tay) và Keypoint 2 (Khớp ngón giữa)
        final kx0 = (boxRow[4] as num).toDouble();
        final ky0 = (boxRow[5] as num).toDouble();
        final kx2 = (boxRow[8] as num).toDouble();
        final ky2 = (boxRow[9] as num).toDouble();

        final wx = (ax + kx0 / 192.0) * origW;
        final wy = (ay + ky0 / 192.0) * origH;
        final mx = (ax + kx2 / 192.0) * origW;
        final my = (ay + ky2 / 192.0) * origH;

        final vx = mx - wx;
        final vy = my - wy;

        // Dời tâm hộp bàn tay theo hướng ngón tay vươn ra (chuẩn MediaPipe)
        final cx = (ax + dx / 192.0) * origW + 0.5 * vx;
        final cy = (ay + dy / 192.0) * origH + 0.5 * vy;
        final boxSize = math.max(dw, dh) / 192.0 * math.max(origW, origH) * 2.6;

        final x1 = math.max(0.0, cx - boxSize / 2.0);
        final y1 = math.max(0.0, cy - boxSize / 2.0);
        final x2 = math.min(origW, cx + boxSize / 2.0);
        final y2 = math.min(origH, cy + boxSize / 2.0);

        if (x2 > x1 && y2 > y1) {
          candidates.add(DetectionBox(
            x1: x1,
            y1: y1,
            x2: x2,
            y2: y2,
            confidence: prob,
            label: 'Bàn tay',
          ));
        }
      }
    }

    // NMS sơ bộ trên các vùng lòng bàn tay
    final filteredPalms = <DetectionBox>[];
    _applyNms(candidates, filteredPalms, iouThreshold: 0.35);

    // Giai đoạn 2: Trích xuất 21 điểm đốt ngón tay bằng _handLandmarksSession
    final rawHands = <DetectionBox>[];
    final maxHandsToProcess = math.min(3, filteredPalms.length);

    for (int p = 0; p < maxHandsToProcess; p++) {
      final palm = filteredPalms[p];
      bool landmarkSuccess = false;

      if (_handLandmarksSession != null) {
        final cropX1 = palm.x1;
        final cropY1 = palm.y1;
        final cropX2 = palm.x2;
        final cropY2 = palm.y2;
        final cropW = (cropX2 - cropX1).toInt();
        final cropH = (cropY2 - cropY1).toInt();

        if (cropW > 16 && cropH > 16) {
          final cropped = img.copyCrop(image, x: cropX1.toInt(), y: cropY1.toInt(), width: cropW, height: cropH);
          const lmTargetSize = _lmTargetSize;
          final resizedLandmarks = img.copyResize(
            cropped,
            width: lmTargetSize,
            height: lmTargetSize,
            interpolation: img.Interpolation.linear,
          );

          final lmBytes = resizedLandmarks.buffer.asUint8List();
          final lmHasAlpha = resizedLandmarks.numChannels == 4;
          final lmStep = lmHasAlpha ? 4 : 3;
          final lmNumPixels = lmTargetSize * lmTargetSize;

          int lmIdx = 0;
          int lmSrcIdx = 0;
          for (int i = 0; i < lmNumPixels; i++) {
            _landmarkInputBuffer[lmIdx++] = lmBytes[lmSrcIdx] / 255.0;
            _landmarkInputBuffer[lmIdx++] = lmBytes[lmSrcIdx + 1] / 255.0;
            _landmarkInputBuffer[lmIdx++] = lmBytes[lmSrcIdx + 2] / 255.0;
            lmSrcIdx += lmStep;
          }

          final lmTensor = OrtValueTensor.createTensorWithDataList(
            _landmarkInputBuffer,
            [1, lmTargetSize, lmTargetSize, 3],
          );

          final lmRunOptions = OrtRunOptions();
          final lmOutputs = await _handLandmarksSession!.runAsync(lmRunOptions, {'input_1': lmTensor});
          lmTensor.release();
          lmRunOptions.release();

          if (lmOutputs != null && lmOutputs.length >= 2) {
            final landmarksVal = lmOutputs[0]?.value; // [1, 63]
            final presenceVal = lmOutputs[1]?.value; // [1, 1]

            for (final o in lmOutputs) {
              o?.release();
            }

            if (landmarksVal is List && landmarksVal.isNotEmpty && presenceVal is List) {
              final rawPres = (presenceVal[0] as List)[0] as num;
              final presence = 1.0 / (1.0 + math.exp(-rawPres.toDouble()));

              if (presence >= 0.45) {
                final lms = landmarksVal[0] as List<dynamic>;
                if (lms.length >= 63) {
                  double minX = double.infinity, minY = double.infinity;
                  double maxX = -double.infinity, maxY = -double.infinity;
                  final landmarkPoints = <Offset>[];

                  // Lấy 21 điểm đốt ngón tay đưa về tọa độ pixel thực tế
                  for (int k = 0; k < 21; k++) {
                    final lx = cropX1 + ((lms[k * 3 + 0] as num).toDouble() / 224.0) * cropW;
                    final ly = cropY1 + ((lms[k * 3 + 1] as num).toDouble() / 224.0) * cropH;
                    landmarkPoints.add(Offset(lx, ly));
                    if (lx < minX) minX = lx;
                    if (ly < minY) minY = ly;
                    if (lx > maxX) maxX = lx;
                    if (ly > maxY) maxY = ly;
                  }

                  // Cộng thêm 25% padding an toàn chuẩn như app.py MediaPipe
                  final padX = (maxX - minX) * 0.25;
                  final padY = (maxY - minY) * 0.25;
                  final finalX1 = math.max(0.0, minX - padX);
                  final finalY1 = math.max(0.0, minY - padY);
                  final finalX2 = math.min(origW, maxX + padX);
                  final finalY2 = math.min(origH, maxY + padY);

                  rawHands.add(DetectionBox(
                    x1: finalX1,
                    y1: finalY1,
                    x2: finalX2,
                    y2: finalY2,
                    confidence: presence,
                    label: 'Bàn tay',
                    landmarks: landmarkPoints,
                  ));
                  landmarkSuccess = true;
                }
              }
            }
          }
        }
      }

      // Dự phòng nếu không trích xuất được 21 landmarks: Dùng vùng tay mở rộng
      if (!landmarkSuccess) {
        final padX = (palm.x2 - palm.x1) * 0.15;
        final padY = (palm.y2 - palm.y1) * 0.15;
        rawHands.add(DetectionBox(
          x1: math.max(0.0, palm.x1 - padX),
          y1: math.max(0.0, palm.y1 - padY),
          x2: math.min(origW, palm.x2 + padX),
          y2: math.min(origH, palm.y2 + padY),
          confidence: palm.confidence,
          label: 'Bàn tay',
        ));
      }
    }

    _applyNms(rawHands, outHands, iouThreshold: 0.35);
  }

  void _applyNms(List<DetectionBox> boxes, List<DetectionBox> results, {double iouThreshold = 0.35}) {
    boxes.sort((a, b) => b.confidence.compareTo(a.confidence));
    final keep = <bool>[];
    for (int i = 0; i < boxes.length; i++) {
      keep.add(true);
    }

    for (int i = 0; i < boxes.length; i++) {
      if (!keep[i]) continue;
      results.add(boxes[i]);
      if (results.length >= 3) break;

      final a = boxes[i].toRect();
      for (int j = i + 1; j < boxes.length; j++) {
        if (!keep[j]) continue;
        final b = boxes[j].toRect();
        final inter = a.intersect(b);
        if (inter.width > 0 && inter.height > 0) {
          final interArea = inter.width * inter.height;
          final unionArea = (a.width * a.height) + (b.width * b.height) - interArea;
          if (unionArea > 0 && (interArea / unionArea) > iouThreshold) {
            keep[j] = false;
          }
        }
      }
    }
  }

  void dispose() {
    _phoneSession?.release();
    _handPalmSession?.release();
    _handLandmarksSession?.release();
    OrtEnv.instance.release();
    _isInitialized = false;
  }
}
