#!/bin/bash
set -e

echo "========================================================"
echo "    ANTI-SPY DETECTION SYSTEM - UBUNTU BUILD SCRIPT     "
echo "========================================================"

# 1. Cài đặt các gói phụ thuộc hệ thống cần thiết trên Ubuntu
echo "[1/4] Đang cài đặt các thư viện hệ thống cần thiết (apt)..."
sudo apt-get update -y
sudo apt-get install -y \
  curl \
  git \
  wget \
  unzip \
  xz-utils \
  zip \
  clang \
  cmake \
  ninja-build \
  pkg-config \
  libgtk-3-dev \
  liblzma-dev \
  libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev \
  libgstreamer-plugins-good1.0-dev \
  gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad \
  gstreamer1.0-plugins-ugly \
  gstreamer1.0-libav \
  gstreamer1.0-tools \
  v4l-utils

# 2. Kiểm tra Flutter SDK
echo "[2/4] Kiểm tra Flutter SDK..."
if ! command -v flutter &> /dev/null; then
    echo "[-] Flutter chưa được cài đặt. Đang tải và cài đặt Flutter SDK..."
    cd /opt
    sudo wget -q https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.5-stable.tar.xz
    sudo tar -xf flutter_linux_3.24.5-stable.tar.xz
    export PATH="$PATH:/opt/flutter/bin"
    echo 'export PATH="$PATH:/opt/flutter/bin"' >> ~/.bashrc
    cd -
fi

echo "[+] Kích hoạt Linux Desktop cho Flutter..."
flutter config --enable-linux-desktop

# 3. Lấy dependencies của dự án
echo "[3/4] Cài đặt dependencies (flutter pub get)..."
cd "$(dirname "$0")/.."
flutter pub get

# 4. Build Release cho Linux
echo "[4/4] Đang biên dịch bản Release cho Ubuntu Linux (flutter build linux --release)..."
flutter build linux --release

echo ""
echo "========================================================"
echo " [SUCCESS] ĐÃ ĐÓNG GÓI HOÀN TẤT CHO UBUNTU!"
echo " Thư mục Bundle chạy độc lập:"
echo " $(pwd)/build/linux/x64/release/bundle/"
echo " File thực thi chính: ./antispy_detector"
echo "========================================================"
