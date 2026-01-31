import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ipc_client.dart';
import 'vpn_provider.dart';

/// Data point for bandwidth history
class BandwidthDataPoint {
  final DateTime timestamp;
  final double uploadSpeed; // bytes per second
  final double downloadSpeed; // bytes per second

  const BandwidthDataPoint({
    required this.timestamp,
    required this.uploadSpeed,
    required this.downloadSpeed,
  });
}

/// State for bandwidth tracking
class BandwidthState {
  final List<BandwidthDataPoint> dataPoints;
  final double currentUploadSpeed;
  final double currentDownloadSpeed;
  final int totalBytesSent;
  final int totalBytesReceived;

  const BandwidthState({
    this.dataPoints = const [],
    this.currentUploadSpeed = 0,
    this.currentDownloadSpeed = 0,
    this.totalBytesSent = 0,
    this.totalBytesReceived = 0,
  });

  factory BandwidthState.empty() => const BandwidthState();

  BandwidthState copyWith({
    List<BandwidthDataPoint>? dataPoints,
    double? currentUploadSpeed,
    double? currentDownloadSpeed,
    int? totalBytesSent,
    int? totalBytesReceived,
  }) {
    return BandwidthState(
      dataPoints: dataPoints ?? this.dataPoints,
      currentUploadSpeed: currentUploadSpeed ?? this.currentUploadSpeed,
      currentDownloadSpeed: currentDownloadSpeed ?? this.currentDownloadSpeed,
      totalBytesSent: totalBytesSent ?? this.totalBytesSent,
      totalBytesReceived: totalBytesReceived ?? this.totalBytesReceived,
    );
  }

  /// Get max speed for Y-axis scaling
  double get maxSpeed {
    if (dataPoints.isEmpty) return 1024; // 1 KB/s minimum
    double max = 1024;
    for (final point in dataPoints) {
      if (point.uploadSpeed > max) max = point.uploadSpeed;
      if (point.downloadSpeed > max) max = point.downloadSpeed;
    }
    return max * 1.1; // Add 10% padding
  }
}

/// Notifier for bandwidth state management
class BandwidthNotifier extends StateNotifier<BandwidthState> {
  static const maxDataPoints = 60; // 60 seconds of history

  final List<BandwidthDataPoint> _dataPoints = [];
  int _lastBytesSent = 0;
  int _lastBytesReceived = 0;
  DateTime? _lastUpdate;

  BandwidthNotifier() : super(BandwidthState.empty());

  /// Update bandwidth data from VPN status
  void updateFromStatus(VpnStatus status) {
    final now = DateTime.now();

    // Calculate time delta for accurate speed calculation
    final timeDelta = _lastUpdate != null
        ? now.difference(_lastUpdate!).inMilliseconds / 1000.0
        : 1.0;

    // Calculate speed (bytes per second)
    double uploadSpeed = 0;
    double downloadSpeed = 0;

    if (_lastUpdate != null && timeDelta > 0) {
      final bytesSentDelta = status.bytesSent - _lastBytesSent;
      final bytesReceivedDelta = status.bytesReceived - _lastBytesReceived;

      // Only count positive deltas (avoid negative on reconnect)
      if (bytesSentDelta >= 0) {
        uploadSpeed = bytesSentDelta / timeDelta;
      }
      if (bytesReceivedDelta >= 0) {
        downloadSpeed = bytesReceivedDelta / timeDelta;
      }
    }

    _dataPoints.add(BandwidthDataPoint(
      timestamp: now,
      uploadSpeed: uploadSpeed,
      downloadSpeed: downloadSpeed,
    ));

    // Keep only last 60 points
    while (_dataPoints.length > maxDataPoints) {
      _dataPoints.removeAt(0);
    }

    _lastBytesSent = status.bytesSent;
    _lastBytesReceived = status.bytesReceived;
    _lastUpdate = now;

    state = BandwidthState(
      dataPoints: List.unmodifiable(_dataPoints),
      currentUploadSpeed: uploadSpeed,
      currentDownloadSpeed: downloadSpeed,
      totalBytesSent: status.bytesSent,
      totalBytesReceived: status.bytesReceived,
    );
  }

  /// Reset all bandwidth data (when disconnecting)
  void reset() {
    _dataPoints.clear();
    _lastBytesSent = 0;
    _lastBytesReceived = 0;
    _lastUpdate = null;
    state = BandwidthState.empty();
  }
}

/// Provider for bandwidth state
final bandwidthProvider =
    StateNotifierProvider<BandwidthNotifier, BandwidthState>((ref) {
  final notifier = BandwidthNotifier();

  // Listen to VPN state changes
  ref.listen<VpnState>(vpnProvider, (previous, next) {
    if (next.status.isConnected) {
      // Update bandwidth data when connected
      notifier.updateFromStatus(next.status);
    } else if (previous?.status.isConnected == true &&
        !next.status.isConnected) {
      // Reset when disconnecting
      notifier.reset();
    }
  });

  return notifier;
});
