import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/detection_models.dart';
import '../services/camera_permission_service.dart';
import '../services/hardware_info_service.dart';
import '../services/on_device_detector_service.dart';
import '../widgets/zone_overlay_painter.dart';

class AntiSpyHomeScreen extends StatefulWidget {
  const AntiSpyHomeScreen({super.key});

  @override
  State<AntiSpyHomeScreen> createState() => _AntiSpyHomeScreenState();
}

class _AntiSpyHomeScreenState extends State<AntiSpyHomeScreen> {
  final OnDeviceDetectorService _detectorService = OnDeviceDetectorService();

  // Hardware & Permission info
  SystemHardwareInfo? _hardwareInfo;
  CameraAccessStatus _cameraStatus = CameraAccessStatus.checking;
  String _cameraStatusMessage = 'Đang khởi động camera...';

  // Camera & Video Streaming
  CameraController? _cameraController;
  List<CameraDescription> _availableCameras = [];
  bool _isCameraInitializing = false;
  bool _isCameraStreaming = false;
  bool _flipVideo = true; // Đảo lại video mặc định theo yêu cầu
  bool _flipDetection = false;
  Timer? _frameProcessTimer;
  bool _isProcessingFrame = false;

  // Test Image fallback
  Uint8List? _testImageBytes;
  String? _testImageName;

  // Warning Zone [0.0 - 1.0]
  Rect _warningZone = const Rect.fromLTRB(0.15, 0.15, 0.85, 0.85);
  Offset? _dragStart;
  bool _isDrawingZone = false;
  bool _isZoneDrawingModeActive = false; // "kẻ zône thì bấm kẻ mới kẻ, ko bấm kẻ thì thôi"

  // AI & Alarm State (Hysteresis 3.0s)
  bool _isAlarmActive = false;
  double _remainingDelaySeconds = 0.0;
  final double _alarmHoldDurationSeconds = 3.0;
  Timer? _delayTicker;
  DateTime? _lastAlarmInstantTime;

  // Detection Data
  DetectFrameResponse? _lastDetection;
  int _handsCount = 0;
  int _phonesCount = 0;
  double _overlapRatio = 0.0;
  double _latencyMs = 0.0;
  int _fps = 0;
  int _frameCount = 0;
  DateTime _lastFpsCalculation = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startAppPipeline();
    });
    _startDelayTicker();
  }

  @override
  void dispose() {
    _frameProcessTimer?.cancel();
    _delayTicker?.cancel();
    _cameraController?.dispose();
    _detectorService.dispose();
    super.dispose();
  }

  /// Khởi chạy tuần tự: Hardware -> ONNX AI -> Camera
  Future<void> _startAppPipeline() async {
    // 1. Quét thông tin phần cứng
    final hw = await HardwareInfoService.detectHardware();
    if (mounted) setState(() => _hardwareInfo = hw);

    // 2. Khởi tạo mô hình ONNX
    await _initOnDeviceAi();

    // 3. Khởi tạo Camera trực tiếp
    await _initCamera();
  }

  /// Khởi tạo AI ONNX Runtime trực tiếp trong Flutter
  Future<void> _initOnDeviceAi() async {
    final cores = _hardwareInfo?.cpuCores;
    await _detectorService.initialize(threadCount: cores);
    if (mounted) setState(() {});
  }

  /// Ticker đếm ngược 3s cho Hysteresis Delay
  void _startDelayTicker() {
    _delayTicker = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (_lastAlarmInstantTime != null) {
        final elapsed = DateTime.now().difference(_lastAlarmInstantTime!).inMilliseconds / 1000.0;
        final remaining = _alarmHoldDurationSeconds - elapsed;

        if (remaining > 0) {
          if (!_isAlarmActive || (_remainingDelaySeconds - remaining).abs() > 0.05) {
            setState(() {
              _isAlarmActive = true;
              _remainingDelaySeconds = remaining;
            });
          }
        } else {
          if (_isAlarmActive) {
            setState(() {
              _isAlarmActive = false;
              _remainingDelaySeconds = 0.0;
              _lastAlarmInstantTime = null;
            });
          }
        }
      }
    });
  }

  /// Khởi tạo Camera phần cứng với cơ chế fallback tự động
  Future<void> _initCamera() async {
    setState(() {
      _isCameraInitializing = true;
      _cameraStatusMessage = 'Đang dò tìm thiết bị Webcam...';
    });

    try {
      _availableCameras = await availableCameras();
      if (_availableCameras.isEmpty) {
        if (mounted) {
          setState(() {
            _isCameraInitializing = false;
            _cameraStatus = CameraAccessStatus.noHardwareFound;
            _cameraStatusMessage = 'Không tìm thấy Webcam phần cứng nào được kết nối';
          });
        }
        return;
      }

      final camera = _availableCameras.first;
      CameraController? activeController;
      Object? lastError;

      // Thử khởi tạo với các preset độ phân giải theo thứ tự: medium -> low -> high
      final presetsToTry = [
        ResolutionPreset.medium,
        ResolutionPreset.low,
        ResolutionPreset.high,
      ];

      for (final preset in presetsToTry) {
        try {
          final controller = CameraController(
            camera,
            preset,
            enableAudio: false,
          );
          await controller.initialize();
          activeController = controller;
          break;
        } catch (e) {
          lastError = e;
        }
      }

      if (activeController != null && activeController.value.isInitialized) {
        if (mounted) {
          setState(() {
            _cameraController = activeController;
            _isCameraInitializing = false;
            _cameraStatus = CameraAccessStatus.granted;
            _cameraStatusMessage = 'Camera đang hoạt động (${camera.name})';
          });
          _startStreaming();
        }
      } else {
        if (mounted) {
          setState(() {
            _isCameraInitializing = false;
            _cameraStatus = CameraAccessStatus.error;
            _cameraStatusMessage = 'Lỗi kết nối Webcam (${camera.name}): $lastError';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCameraInitializing = false;
          _cameraStatus = CameraAccessStatus.error;
          _cameraStatusMessage = 'Lỗi truy cập hệ thống camera: $e';
        });
      }
    }
  }

  /// Bắt đầu chu kỳ chụp frame và suy luận AI On-Device
  void _startStreaming() {
    if (_frameProcessTimer != null && _frameProcessTimer!.isActive) return;
    _isCameraStreaming = true;

    // Chạy chu kỳ lấy frame và phát hiện AI (tối ưu 100ms cho Intel N97)
    _frameProcessTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) async {
      if (!_isCameraStreaming || _isProcessingFrame) return;

      if (_cameraController != null && _cameraController!.value.isInitialized) {
        _isProcessingFrame = true;
        try {
          final xfile = await _cameraController!.takePicture();
          final bytes = await xfile.readAsBytes();

          // Bảo mật & Tiết kiệm bộ nhớ: Xóa ngay file ảnh tạm trên đĩa
          try {
            final f = File(xfile.path);
            if (await f.exists()) {
              await f.delete();
            }
          } catch (_) {}

          await _processImageBytes(bytes);
        } catch (_) {
        } finally {
          _isProcessingFrame = false;
        }
      }
    });
  }

  void _stopStreaming() {
    _frameProcessTimer?.cancel();
    setState(() => _isCameraStreaming = false);
  }

  /// Xử lý ảnh hoàn toàn On-Device qua OnDeviceDetectorService
  Future<void> _processImageBytes(Uint8List bytes) async {
    final start = DateTime.now();

    final effectiveZone = _flipDetection
        ? Rect.fromLTRB(
            1.0 - _warningZone.right,
            _warningZone.top,
            1.0 - _warningZone.left,
            _warningZone.bottom,
          )
        : _warningZone;

    final resp = await _detectorService.detectFrame(
      imageBytes: bytes,
      warningZone: effectiveZone,
      phoneThreshold: 0.70,
      handThreshold: 0.70,
    );

    final duration = DateTime.now().difference(start).inMilliseconds.toDouble();

    if (mounted && resp != null) {
      _frameCount++;
      final now = DateTime.now();
      if (now.difference(_lastFpsCalculation).inMilliseconds >= 1000) {
        _fps = _frameCount;
        _frameCount = 0;
        _lastFpsCalculation = now;
      }

      // Xử lý Cảnh Báo & Hysteresis 3s
      if (resp.alarmInstant) {
        _lastAlarmInstantTime = DateTime.now();
        _isAlarmActive = true;
        _remainingDelaySeconds = _alarmHoldDurationSeconds;
      }

      setState(() {
        _lastDetection = resp;
        _handsCount = resp.handsCount;
        _phonesCount = resp.phonesCount;
        _overlapRatio = resp.overlapRatio;
        _latencyMs = duration;
      });
    }
  }

  /// Chọn file ảnh từ bộ nhớ để kiểm tra
  Future<void> _pickTestImage() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
    );

    if (files.isNotEmpty) {
      final file = files.first;
      final bytes = await file.readAsBytes();
      setState(() {
        _testImageBytes = bytes;
        _testImageName = file.name;
      });
      await _processImageBytes(bytes);
    }
  }

  void _setZonePreset(String preset) {
    setState(() {
      switch (preset) {
        case 'center':
          _warningZone = const Rect.fromLTRB(0.2, 0.2, 0.8, 0.8);
          break;
        case 'full':
          _warningZone = const Rect.fromLTRB(0.05, 0.05, 0.95, 0.95);
          break;
        case 'top':
          _warningZone = const Rect.fromLTRB(0.1, 0.05, 0.9, 0.5);
          break;
        case 'bottom':
          _warningZone = const Rect.fromLTRB(0.1, 0.5, 0.9, 0.95);
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopAppBar(),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Màn hình hiển thị Camera / Image
                  Expanded(
                    flex: 7,
                    child: _buildCameraViewport(),
                  ),
                  // Cột điều khiển & số liệu bên phải
                  Container(
                    width: 380,
                    decoration: const BoxDecoration(
                      color: Color(0xFF111827),
                      border: Border(left: BorderSide(color: Color(0xFF1F2937))),
                    ),
                    child: _buildSidebarControls(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Thanh AppBar phía trên với thông tin Hardware Engine
  Widget _buildTopAppBar() {
    final gpuText = _hardwareInfo?.gpuName ?? 'GPU / CPU';
    final isGpu = _hardwareInfo?.hasDedicatedGpu ?? false;

    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        border: Border(bottom: BorderSide(color: Color(0xFF1F2937))),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF06B6D4).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF06B6D4), width: 1),
            ),
            child: const Text(
              'AGY',
              style: TextStyle(
                color: Color(0xFF06B6D4),
                fontWeight: FontWeight.w900,
                fontSize: 14,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'ANTI-SPY DETECTION SYSTEM',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  letterSpacing: 1.1,
                ),
              ),
              Text(
                'Pure Dart & ONNX Runtime • ${_hardwareInfo?.osName ?? 'Desktop Native'}',
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
              ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: isGpu
                  ? const Color(0xFF059669).withValues(alpha: 0.15)
                  : const Color(0xFF0284C7).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isGpu ? const Color(0xFF10B981) : const Color(0xFF38BDF8),
                width: 1,
              ),
            ),
            child: Text(
              isGpu ? 'GPU: $gpuText' : 'Engine: ${_hardwareInfo?.cpuName ?? "CPU Multithread"}',
              style: TextStyle(
                color: isGpu ? const Color(0xFF10B981) : const Color(0xFF38BDF8),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Khung hiển thị Camera & Hiệu ứng làm mờ (Blur) khi Cảnh Báo
  Widget _buildCameraViewport() {
    final hasActiveVisual = (_cameraController != null && _cameraController!.value.isInitialized) ||
        _testImageBytes != null;

    if (!hasActiveVisual) {
      return Container(
        color: Colors.black,
        child: _buildCameraFallback(),
      );
    }

    double visualAspectRatio = 4 / 3;
    if (_lastDetection != null && _lastDetection!.imageWidth > 0 && _lastDetection!.imageHeight > 0) {
      visualAspectRatio = _lastDetection!.imageWidth / _lastDetection!.imageHeight;
    } else if (_cameraController != null && _cameraController!.value.isInitialized) {
      visualAspectRatio = _cameraController!.value.aspectRatio;
    }

    return Container(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: visualAspectRatio,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final visualW = constraints.maxWidth;
              final visualH = constraints.maxHeight;
              final destRect = Rect.fromLTWH(0, 0, visualW, visualH);

              return Stack(
                fit: StackFit.expand,
                children: [
                  // 1. Lớp Video / Ảnh với Hỗ trợ Đảo Chiều Video
                  ClipRect(
                    child: Transform(
                      alignment: Alignment.center,
                      transform: (_flipVideo && _testImageBytes == null)
                          ? Matrix4.rotationY(math.pi)
                          : Matrix4.identity(),
                      child: _testImageBytes != null
                          ? Image.memory(
                              _testImageBytes!,
                              fit: BoxFit.fill,
                            )
                          : (_cameraController != null && _cameraController!.value.isInitialized
                              ? CameraPreview(_cameraController!)
                              : const SizedBox.shrink()),
                    ),
                  ),

                  // 2. Lớp Màn Hình Cảnh Báo Opacity 0.4 (không tối đen)
                  if (_isAlarmActive)
                    Container(
                      color: Colors.black.withValues(alpha: 0.4),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                              decoration: BoxDecoration(
                                color: const Color(0xFFDC2626).withValues(alpha: 0.3),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFFEF4444), width: 2),
                              ),
                              child: const Text(
                                '[ PHÁT HIỆN HÀNH VI CHỤP LÉN ]',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Color(0xFFEF4444),
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ),
                            if (_remainingDelaySeconds > 0) ...[
                              const SizedBox(height: 16),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEF4444).withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: const Color(0xFFEF4444)),
                                ),
                                child: Text(
                                  'Khóa an toàn còn: ${_remainingDelaySeconds.toStringAsFixed(1)}s (Hold 3s)',
                                  style: const TextStyle(
                                    color: Color(0xFFFCA5A5),
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                  // 3. Lớp Vẽ Vùng & Detections (ZoneOverlayPainter)
                  GestureDetector(
                    onPanStart: _isZoneDrawingModeActive
                        ? (details) {
                            setState(() {
                              _isDrawingZone = true;
                              _dragStart = details.localPosition;
                            });
                          }
                        : null,
                    onPanUpdate: _isZoneDrawingModeActive
                        ? (details) {
                            setState(() {
                              if (_dragStart != null && visualW > 0 && visualH > 0) {
                                final x1 = (_dragStart!.dx / visualW).clamp(0.0, 1.0);
                                final y1 = (_dragStart!.dy / visualH).clamp(0.0, 1.0);
                                final x2 = (details.localPosition.dx / visualW).clamp(0.0, 1.0);
                                final y2 = (details.localPosition.dy / visualH).clamp(0.0, 1.0);

                                _warningZone = Rect.fromLTRB(
                                  math.min(x1, x2),
                                  math.min(y1, y2),
                                  math.max(x1, x2),
                                  math.max(y1, y2),
                                );
                              }
                            });
                          }
                        : null,
                    onPanEnd: _isZoneDrawingModeActive
                        ? (_) {
                            setState(() {
                              _isDrawingZone = false;
                              _dragStart = null;
                              _isZoneDrawingModeActive = false;
                            });
                          }
                        : null,
                    child: CustomPaint(
                      painter: ZoneOverlayPainter(
                        warningZoneNormalized: _warningZone,
                        isDrawing: _isDrawingZone,
                        isAlarm: _isAlarmActive,
                        isMirrored: _flipDetection,
                        hands: _lastDetection?.hands ?? [],
                        phones: _lastDetection?.phones ?? [],
                        originalImageSize: Size(
                          _lastDetection?.imageWidth ?? visualW,
                          _lastDetection?.imageHeight ?? visualH,
                        ),
                        destinationRect: destRect,
                      ),
                    ),
                  ),

                  // 4. Banner Cảnh Báo duy nhất
                  if (_isAlarmActive)
                    Positioned(
                      top: 20,
                      left: 20,
                      right: 20,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFDC2626),
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.red.withValues(alpha: 0.6),
                                blurRadius: 16,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                '[ CẢNH BÁO: PHÁT HIỆN THIẾT BỊ LÉN ]',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              if (_remainingDelaySeconds > 0) ...[
                                const SizedBox(width: 14),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.35),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    'Giữ ${_remainingDelaySeconds.toStringAsFixed(1)}s',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),

                  // 5. Hướng dẫn khi đang bật chế độ vẽ vùng
                  if (_isZoneDrawingModeActive)
                    Positioned(
                      top: 16,
                      left: 16,
                      right: 16,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0284C7).withValues(alpha: 0.95),
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 8)],
                          ),
                          child: const Text(
                            'CHẾ ĐỘ KẺ VÙNG ĐANG BẬT: Bấm giữ và kéo chuột trên khung hình để tạo vùng giám sát mới',
                            style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Giao diện khi Webcam chưa sẵn sàng hoặc đang khởi động
  Widget _buildCameraFallback() {
    if (_isCameraInitializing) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF06B6D4)),
            SizedBox(height: 16),
            Text('Đang dò tìm và mở Webcam phần cứng...', style: TextStyle(color: Colors.white, fontSize: 15)),
          ],
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Text(
                _cameraStatus == CameraAccessStatus.denied
                    ? '[ QUYỀN CAMERA BỊ TỪ CHỐI ]'
                    : '[ TÍN HIỆU CAMERA CHƯA KHỞI ĐỘNG ]',
                style: const TextStyle(color: Color(0xFF94A3B8), fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'WEBCAM CHƯA HOẠT ĐỘNG',
              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _cameraStatusMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: _initCamera,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF06B6D4),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  child: const Text('Thử lại / Mở lại Camera', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                ElevatedButton(
                  onPressed: CameraPermissionService.openSystemCameraSettings,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF475569),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  child: const Text('Mở Cài đặt Quyền riêng tư', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                OutlinedButton(
                  onPressed: _pickTestImage,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF0284C7)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  child: const Text('Chọn ảnh mẫu thử nghiệm', style: TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Cột điều khiển & số liệu bên phải
  Widget _buildSidebarControls() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // 1. Trạng thái cảnh báo Hysteresis
        _buildAlertStatusCard(),
        const SizedBox(height: 20),

        // 2. Chế độ Vẽ Vùng Cảnh Báo
        _buildSectionHeader('VÙNG CẢNH BÁO GIÁM SÁT'),
        const SizedBox(height: 10),
        _buildZoneDrawingControl(),
        const SizedBox(height: 12),
        _buildZonePresets(),
        const SizedBox(height: 24),

        // 3. Chỉ số nhận diện AI On-Device
        _buildSectionHeader('CHỈ SỐ THỜI GIAN THỰC (ON-DEVICE)'),
        const SizedBox(height: 10),
        _buildMetricsGrid(),
        const SizedBox(height: 24),

        // 4. Nguồn phát
        _buildSectionHeader('ĐIỀU KHIỂN NGUỒN PHÁT'),
        const SizedBox(height: 10),
        _buildSourceControls(),
        const SizedBox(height: 24),

        // 5. Kiểm tra CPU & GPU phần cứng hệ điều hành
        _buildHardwareInfoCard(),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Container(
      padding: const EdgeInsets.only(bottom: 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF1E293B), width: 1)),
      ),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFF94A3B8),
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.0,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// Nút bật/tắt chế độ kẻ vùng ("kẻ zône thì bấm kẻ mới kẻ, ko bấm kẻ thì thôi")
  Widget _buildZoneDrawingControl() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton(
          onPressed: () {
            setState(() {
              _isZoneDrawingModeActive = !_isZoneDrawingModeActive;
              _dragStart = null;
              _isDrawingZone = false;
            });
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: _isZoneDrawingModeActive ? const Color(0xFF10B981) : const Color(0xFF0284C7),
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Text(
            _isZoneDrawingModeActive ? 'HOÀN TẤT VẼ VÙNG' : 'BẬT CHẾ ĐỘ KẺ VÙNG',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _isZoneDrawingModeActive
              ? 'Giờ bạn có thể kéo chuột trên màn hình để tạo khung vùng'
              : 'Chỉ khi bấm nút trên bạn mới có thể kéo chuột kẻ vùng mới.',
          style: TextStyle(
            color: _isZoneDrawingModeActive ? const Color(0xFF34D399) : const Color(0xFF64748B),
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  /// Thẻ trạng thái cảnh báo nổi bật
  Widget _buildAlertStatusCard() {
    final statusColor = _isAlarmActive ? const Color(0xFFEF4444) : const Color(0xFF10B981);
    final statusBg = _isAlarmActive
        ? const Color(0xFFEF4444).withValues(alpha: 0.15)
        : const Color(0xFF10B981).withValues(alpha: 0.15);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: statusBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: statusColor),
                ),
                child: Text(
                  _isAlarmActive ? '[!]' : '[OK]',
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isAlarmActive ? 'CẢNH BÁO' : 'AN TOÀN',
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.0,
                      ),
                    ),
                    Text(
                      _isAlarmActive
                          ? 'Phát hiện điện thoại trong vùng'
                          : 'Không có hành vi chụp lén',
                      style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_isAlarmActive) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: (_remainingDelaySeconds / _alarmHoldDurationSeconds).clamp(0.0, 1.0),
              backgroundColor: Colors.black26,
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFEF4444)),
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
            const SizedBox(height: 6),
            Text(
              'Đang duy trì cảnh báo: ${_remainingDelaySeconds.toStringAsFixed(1)}s (Hold 3s)',
              style: const TextStyle(color: Color(0xFFF87171), fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }

  /// Lưới chỉ số AI On-Device
  Widget _buildMetricsGrid() {
    final isHolding = _lastDetection?.holdingPhone ?? false;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _buildMetricTile(
                'Bàn tay',
                '$_handsCount (>=0.60)',
                _handsCount > 0 ? const Color(0xFFFACC15) : const Color(0xFF64748B),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildMetricTile(
                'Điện thoại',
                '$_phonesCount (>=0.60)',
                _phonesCount > 0 ? const Color(0xFF38BDF8) : const Color(0xFF64748B),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildMetricTile(
                'Cầm ĐT (Chụp lén)',
                isHolding ? 'PHÁT HIỆN' : 'KHÔNG CÓ',
                isHolding ? const Color(0xFFEF4444) : const Color(0xFF10B981),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildMetricTile(
                'Giao thoa vùng',
                '${(_overlapRatio * 100).toStringAsFixed(0)}%',
                _overlapRatio > 0.1 ? const Color(0xFFF97316) : const Color(0xFF64748B),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _buildMetricTile(
                'Độ trễ / Tốc độ',
                '${_latencyMs.toStringAsFixed(0)}ms | $_fps FPS',
                const Color(0xFF06B6D4),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMetricTile(String label, String value, Color accentColor) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accentColor,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// Preset Vùng Cảnh Báo
  Widget _buildZonePresets() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _presetButton('Mặc định (Trung tâm)', () => _setZonePreset('center')),
        _presetButton('Toàn khung', () => _setZonePreset('full')),
        _presetButton('Nửa trên', () => _setZonePreset('top')),
        _presetButton('Nửa dưới', () => _setZonePreset('bottom')),
      ],
    );
  }

  Widget _presetButton(String title, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: Text(
          title,
          style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 12),
        ),
      ),
    );
  }

  /// Điều khiển nguồn Camera hoặc Ảnh thử nghiệm
  Widget _buildSourceControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_cameraController != null && _cameraController!.value.isInitialized)
          ElevatedButton(
            onPressed: () {
              if (_isCameraStreaming) {
                _stopStreaming();
              } else {
                _startStreaming();
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _isCameraStreaming ? const Color(0xFFDC2626) : const Color(0xFF059669),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: Text(
              _isCameraStreaming ? 'Tạm dừng Stream' : 'Bật Stream Camera',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () {
            setState(() {
              _flipVideo = !_flipVideo;
            });
          },
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: _flipVideo ? const Color(0xFF10B981) : const Color(0xFF475569)),
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
          child: Text(
            _flipVideo ? 'Đảo chiều Video: ĐANG BẬT' : 'Đảo chiều Video: ĐANG TẮT',
            style: TextStyle(
              color: _flipVideo ? const Color(0xFF34D399) : const Color(0xFF94A3B8),
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () {
            setState(() {
              _flipDetection = !_flipDetection;
            });
          },
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: _flipDetection ? const Color(0xFF10B981) : const Color(0xFF475569)),
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
          child: Text(
            _flipDetection ? 'Đảo chiều Khung Detect: ĐANG BẬT' : 'Đảo chiều Khung Detect: ĐANG TẮT',
            style: TextStyle(
              color: _flipDetection ? const Color(0xFF34D399) : const Color(0xFF94A3B8),
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _pickTestImage,
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFF0284C7)),
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
          child: Text(
            _testImageName != null ? 'Ảnh: $_testImageName' : 'Chọn ảnh kiểm tra On-Device',
            style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (_testImageBytes != null) ...[
          const SizedBox(height: 6),
          TextButton(
            onPressed: () {
              setState(() {
                _testImageBytes = null;
                _testImageName = null;
              });
            },
            child: const Text('Bỏ ảnh test, quay lại camera', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)),
          ),
        ],
      ],
    );
  }

  /// Thông tin kiểm tra CPU, GPU và Engine On-Device
  Widget _buildHardwareInfoCard() {
    final hw = _hardwareInfo;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'PHẦN CỨNG & ONNX RUNTIME',
                style: TextStyle(color: Color(0xFF64748B), fontSize: 10, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              InkWell(
                onTap: _startAppPipeline,
                child: const Text(
                  '[Quét lại]',
                  style: TextStyle(color: Color(0xFF38BDF8), fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _infoRow('Hệ điều hành:', hw?.osName ?? 'Đang quét...'),
          _infoRow('Bộ xử lý (CPU):', '${hw?.cpuName ?? "Multi-core"} (${hw?.cpuCores ?? 0} Cores)'),
          _infoRow('Bộ nhớ RAM:', hw?.totalRam ?? 'N/A'),
          _infoRow('Đồ họa (GPU):', hw?.gpuName ?? 'Tích hợp / Standard'),
          _infoRow('Execution Provider:', hw?.executionProvider ?? 'CPU SIMD'),
          _infoRow('Kiến trúc mạng AI:', 'RF-DETR On-Device (Full Dart)'),
          _infoRow('Bộ lọc cảnh báo:', 'ImageFilter.blur GPU Accelerated'),
          _infoRow('Hysteresis Delay:', '3.0 Giây (Hold & Reset)'),
        ],
      ),
    );
  }

  Widget _infoRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              v,
              textAlign: TextAlign.end,
              style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
