
import 'dart:io';
import 'package:camera/camera.dart';

enum CameraAccessStatus {
  checking,
  granted,
  denied,
  noHardwareFound,
  error,
}

class CameraPermissionService {
  /// Kiểm tra quyền truy cập và phần cứng Camera trên Windows / Linux
  static Future<Map<String, dynamic>> verifyCameraPermission() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        return {
          'status': CameraAccessStatus.granted,
          'message': 'Đã cấp quyền Camera (${cameras.length} thiết bị: ${cameras.first.name})',
          'deviceCount': cameras.length,
          'primaryDevice': cameras.first.name,
          'cameras': cameras,
        };
      } else {
        if (Platform.isWindows) {
          final isBlocked = await _checkWindowsPrivacyDenied();
          if (isBlocked) {
            return {
              'status': CameraAccessStatus.denied,
              'message': 'Camera bị từ chối quyền trong Windows Privacy Settings',
              'deviceCount': 0,
            };
          }
        }

        return {
          'status': CameraAccessStatus.noHardwareFound,
          'message': 'Không tìm thấy thiết bị webcam khả dụng hoặc camera đang bị ứng dụng khác chiếm giữ',
          'deviceCount': 0,
        };
      }
    } catch (e) {
      final errorMsg = e.toString().toLowerCase();
      if (errorMsg.contains('access') || errorMsg.contains('permission') || errorMsg.contains('denied')) {
        return {
          'status': CameraAccessStatus.denied,
          'message': 'Bị hệ thống từ chối quyền truy cập Camera ($e)',
          'deviceCount': 0,
        };
      }
      return {
        'status': CameraAccessStatus.error,
        'message': 'Lỗi khởi tạo thiết bị: $e',
        'deviceCount': 0,
      };
    }
  }

  /// Mở trang cài đặt quyền Camera trên hệ điều hành
  static Future<void> openSystemCameraSettings() async {
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', 'ms-settings:privacy-webcam']);
      } else if (Platform.isLinux) {
        await Process.run('gnome-control-center', ['privacy', 'camera']);
      }
    } catch (_) {}
  }

  static Future<bool> _checkWindowsPrivacyDenied() async {
    try {
      final res = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        '(Get-ItemProperty -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\webcam" -ErrorAction SilentlyContinue).Value',
      ]);
      final val = res.stdout.toString().trim().toLowerCase();
      return val == 'deny';
    } catch (_) {
      return false;
    }
  }
}
