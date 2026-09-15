import 'dart:io';

class SystemHardwareInfo {
  final String osName;
  final String cpuName;
  final int cpuCores;
  final String gpuName;
  final String executionProvider;
  final bool hasDedicatedGpu;
  final String totalRam;

  const SystemHardwareInfo({
    required this.osName,
    required this.cpuName,
    required this.cpuCores,
    required this.gpuName,
    required this.executionProvider,
    required this.hasDedicatedGpu,
    required this.totalRam,
  });
}

class HardwareInfoService {
  /// Quét phần cứng CPU, GPU và Hệ điều hành (Windows / Linux)
  static Future<SystemHardwareInfo> detectHardware() async {
    final osName = Platform.operatingSystem; // 'windows' or 'linux'
    final cpuCores = Platform.numberOfProcessors;

    String cpuName = 'Generic Multi-core CPU';
    String gpuName = 'Standard Display Adapter';
    String totalRam = '8+ GB';
    bool hasDedicatedGpu = false;
    String executionProvider = 'CPU Multithread ($cpuCores Cores)';

    try {
      if (Platform.isWindows) {
        // 1. Quét CPU trên Windows
        try {
          final cpuRes = await Process.run('powershell', [
            '-NoProfile',
            '-Command',
            '(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name).Trim()',
          ]);
          if (cpuRes.exitCode == 0 && cpuRes.stdout.toString().trim().isNotEmpty) {
            cpuName = cpuRes.stdout.toString().trim();
          }
        } catch (_) {}

        // 2. Quét GPU trên Windows
        try {
          final gpuRes = await Process.run('powershell', [
            '-NoProfile',
            '-Command',
            '(Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name) -join " / "',
          ]);
          if (gpuRes.exitCode == 0 && gpuRes.stdout.toString().trim().isNotEmpty) {
            gpuName = gpuRes.stdout.toString().trim();
          }
        } catch (_) {}

        // 3. Quét RAM trên Windows
        try {
          final ramRes = await Process.run('powershell', [
            '-NoProfile',
            '-Command',
            '[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)',
          ]);
          if (ramRes.exitCode == 0 && ramRes.stdout.toString().trim().isNotEmpty) {
            totalRam = '${ramRes.stdout.toString().trim()} GB';
          }
        } catch (_) {}

        // Kiểm tra GPU chuyên dụng (NVIDIA / AMD) hoặc Intel Processor N97
        final lowerCpu = cpuName.toLowerCase();
        final lowerGpu = gpuName.toLowerCase();
        if (lowerCpu.contains('n97') || (lowerCpu.contains('intel') && cpuCores == 4)) {
          executionProvider = 'Intel® N97 Quad-Core • AVX2 + VNNI';
        } else if (lowerGpu.contains('nvidia') || lowerGpu.contains('rtx') || lowerGpu.contains('gtx')) {
          hasDedicatedGpu = true;
          executionProvider = 'DirectML / CUDA GPU Accelerated';
        } else if (lowerGpu.contains('radeon') || lowerGpu.contains('amd')) {
          hasDedicatedGpu = true;
          executionProvider = 'DirectML GPU Accelerated';
        } else {
          executionProvider = 'Intel/AMD AVX2 Multithread ($cpuCores Threads)';
        }
      } else if (Platform.isLinux) {
        // 1. Quét CPU trên Linux
        try {
          final cpuRes = await Process.run('sh', [
            '-c',
            'grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs',
          ]);
          if (cpuRes.exitCode == 0 && cpuRes.stdout.toString().trim().isNotEmpty) {
            cpuName = cpuRes.stdout.toString().trim();
          }
        } catch (_) {}

        // 2. Quét GPU trên Linux
        try {
          final gpuRes = await Process.run('sh', [
            '-c',
            'lspci | grep -iE "vga|3d|display" | cut -d: -f3 | xargs',
          ]);
          if (gpuRes.exitCode == 0 && gpuRes.stdout.toString().trim().isNotEmpty) {
            gpuName = gpuRes.stdout.toString().trim();
          }
        } catch (_) {}

        // 3. Quét RAM trên Linux
        try {
          final ramRes = await Process.run('sh', [
            '-c',
            'free -m | awk \'/^Mem:/{printf "%.1f GB", \$2/1024}\'',
          ]);
          if (ramRes.exitCode == 0 && ramRes.stdout.toString().trim().isNotEmpty) {
            totalRam = ramRes.stdout.toString().trim();
          }
        } catch (_) {}

        final lowerGpu = gpuName.toLowerCase();
        if (lowerGpu.contains('nvidia')) {
          hasDedicatedGpu = true;
          executionProvider = 'CUDA / TensorRT GPU ($gpuName)';
        } else {
          executionProvider = 'Linux OpenMP / CPU ($cpuCores Cores)';
        }
      }
    } catch (_) {}

    return SystemHardwareInfo(
      osName: Platform.isWindows ? 'Windows Desktop (x64)' : (Platform.isLinux ? 'Linux Desktop (x64)' : osName),
      cpuName: cpuName,
      cpuCores: cpuCores,
      gpuName: gpuName,
      executionProvider: executionProvider,
      hasDedicatedGpu: hasDedicatedGpu,
      totalRam: totalRam,
    );
  }
}
