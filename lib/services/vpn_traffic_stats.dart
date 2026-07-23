class VpnTrafficStats {
  final String uploadBytes;
  final String downloadBytes;
  final String uploadSpeed;
  final String downloadSpeed;
  final bool isAvailable;

  const VpnTrafficStats({
    this.uploadBytes = '0',
    this.downloadBytes = '0',
    this.uploadSpeed = '0',
    this.downloadSpeed = '0',
    this.isAvailable = true,
  });

  static const zero = VpnTrafficStats();
  static const unavailable = VpnTrafficStats(
    uploadBytes: '—',
    downloadBytes: '—',
    uploadSpeed: '—',
    downloadSpeed: '—',
    isAvailable: false,
  );
}