# Anti-Spy Detector - Pure Flutter & ONNX Runtime (Zero Backend)

Ứng dụng Flutter Desktop (Linux & Windows) giám sát và cảnh báo hành vi chụp lén hoàn toàn độc lập (**100% On-Device, không cần Python Backend hay bất kỳ cổng port/server nào**).

---

## 🌟 Kiến Trúc Đột Phá (Full Dart + OnnxRuntime)

1. **Không Server / Không Cổng Mạng (Zero Backend)**:
   - Xóa bỏ hoàn toàn server Flask, Python, Docker và cổng 31301.
   - Nhúng mô hình trực tiếp qua `onnxruntime` FFI native (`onnxruntime.dll` trên Windows / `libonnxruntime.so` trên Linux).
   - Tự động nạp model trọng số `phone_detect_weights.onnx` ngay khi khởi động.

2. **Tự động Xin & Kiểm Tra Quyền Camera**:
   - Kiểm tra quyền truy cập phần cứng Camera trên Windows và Linux.
   - Nếu camera bị từ chối hoặc chặn bởi cài đặt quyền riêng tư hệ điều hành (Windows Privacy Settings), ứng dụng hiển thị nút **"Cấp quyền trong Cài đặt hệ thống"** để mở ngay màn hình cấp quyền `ms-settings:privacy-webcam`.
   - Có cơ chế tải ảnh mẫu kiểm tra (`FilePicker`) nếu thiết bị không có webcam phần cứng.

3. **Kiểm Tra & Tối Ưu Phần Cứng (CPU & GPU)**:
   - Tự động quét thông tin CPU (số lõi logic, tên vi xử lý) và card đồ họa GPU (NVIDIA, AMD, Intel).
   - Tự động phân bổ đa luồng tính toán tối ưu cho ONNX Runtime Session (`setIntraOpNumThreads`).

4. **Vẽ Vùng Cảnh Báo Trực Quan (Interactive Warning Zone)**:
   - Kéo chuột tự do trên màn hình để định nghĩa vùng giám sát nguy hiểm.
   - Hỗ trợ các nút chọn nhanh: *Trung tâm*, *Toàn khung hình*, *Nửa trên*, *Nửa dưới*.

5. **Bộ Lọc GPU Làm Mờ (Blur) & Giữ Cảnh Báo 3 Giây (Hysteresis)**:
   - Khi phát hiện giơ điện thoại trong Vùng Cảnh Báo:
     - Kích hoạt bộ lọc mờ màn hình `ImageFilter.blur(sigmaX: 18, sigmaY: 18)` tăng tốc bởi GPU.
     - Hiển thị duy nhất banner **`🚨 CẢNH BÁO`** nổi bật.
     - Đếm ngược duy trì trạng thái 3.0s sau khi hạ điện thoại; tự động reset thời gian nếu tiếp tục phát hiện.

---

## 🚀 Hướng Dẫn Chạy & Đóng Gói

### 1. Trên Windows Desktop

```powershell
# Chạy trực tiếp
flutter run -d windows

# Đóng gói bản phát hành độc lập (Release)
flutter build windows --release
```
Bản phát hành độc lập nằm tại: `build\windows\x64\runner\Release\antispy_detector.exe`

### 2. Trên Linux Desktop (Ubuntu / Debian)

```bash
# Cài đặt thư viện phát triển GTK3 và GStreamer Camera
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-good

# Thêm quyền truy cập camera cho user hiện tại (nếu cần)
sudo usermod -aG video $USER

# Chạy trực tiếp
flutter run -d linux

# Đóng gói phát hành
flutter build linux --release
```
Bản phát hành nằm tại: `build/linux/x64/release/bundle/antispy_detector`
