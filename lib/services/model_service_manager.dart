import 'dart:async';
import 'package:flutter/foundation.dart';
import '../config/pipeline_config.dart';
import 'license_plate_detector_metric_new.dart';

/// Loading state for a pipeline
enum LoadingState {
  notLoaded,
  loading,
  loaded,
  error,
}

/// Loading status with optional error message
class LoadingStatus {
  final LoadingState state;
  final String? errorMessage;
  final double progress; // 0.0 to 1.0

  const LoadingStatus({
    required this.state,
    this.errorMessage,
    this.progress = 0.0,
  });

  bool get isLoaded => state == LoadingState.loaded;
  bool get isLoading => state == LoadingState.loading;
  bool get hasError => state == LoadingState.error;
}

/// Singleton manager for lazy loading and caching model detectors
class ModelServiceManager {
  // Singleton instance
  static final ModelServiceManager _instance = ModelServiceManager._internal();
  factory ModelServiceManager() => _instance;
  ModelServiceManager._internal();

  // Cache for loaded detectors
  final Map<PipelineType, LicensePlateDetectorMetricNew> _detectorCache = {};

  // Loading status for each pipeline
  final Map<PipelineType, LoadingStatus> _loadingStatus = {};

  // Stream controllers for loading state changes
  final Map<PipelineType, StreamController<LoadingStatus>> _statusControllers = {};

  /// Check if a detector is cached and ready
  bool isDetectorCached(PipelineType type) {
    return _detectorCache.containsKey(type) &&
        _detectorCache[type]!.isInitialized;
  }

  /// Get cached detector (returns null if not cached)
  LicensePlateDetectorMetricNew? getCachedDetector(PipelineType type) {
    if (isDetectorCached(type)) {
      return _detectorCache[type];
    }
    return null;
  }

  /// Get loading status for a pipeline
  LoadingStatus getLoadingStatus(PipelineType type) {
    return _loadingStatus[type] ??
        const LoadingStatus(state: LoadingState.notLoaded);
  }

  /// Stream of loading status updates
  Stream<LoadingStatus> getLoadingStatusStream(PipelineType type) {
    _statusControllers[type] ??= StreamController<LoadingStatus>.broadcast();
    return _statusControllers[type]!.stream;
  }

  /// Load and cache a detector for the given pipeline type
  /// Returns the detector when ready
  Future<LicensePlateDetectorMetricNew> getOrLoadDetector(
      PipelineType type, {
        DelegateType delegateType = DelegateType.gpu,
        void Function(LoadingStatus)? onStatusChange,
      }) async {
    // Return cached if available
    if (isDetectorCached(type)) {
      return _detectorCache[type]!;
    }

    // Check if already loading
    if (_loadingStatus[type]?.isLoading == true) {
      // Wait for existing load to complete
      return _waitForDetector(type);
    }

    // Start loading
    _updateStatus(type, const LoadingStatus(
      state: LoadingState.loading,
      progress: 0.0,
    ), onStatusChange);

    try {
      final config = PipelineConfig.getConfig(type);
      final detector = LicensePlateDetectorMetricNew();

      _updateStatus(type, const LoadingStatus(
        state: LoadingState.loading,
        progress: 0.3,
      ), onStatusChange);

      await detector.initialize(
        detModelPath: config.detModelPath,
        ocrModelPath: config.ocrModelPath,
        delegateType: delegateType,
      );

      _updateStatus(type, const LoadingStatus(
        state: LoadingState.loading,
        progress: 0.9,
      ), onStatusChange);

      // Cache the detector
      _detectorCache[type] = detector;

      _updateStatus(type, const LoadingStatus(
        state: LoadingState.loaded,
        progress: 1.0,
      ), onStatusChange);

      return detector;
    } catch (e) {
      _updateStatus(type, LoadingStatus(
        state: LoadingState.error,
        errorMessage: e.toString(),
      ), onStatusChange);
      rethrow;
    }
  }

  /// Wait for an ongoing load to complete
  Future<LicensePlateDetectorMetricNew> _waitForDetector(PipelineType type) async {
    final completer = Completer<LicensePlateDetectorMetricNew>();

    late StreamSubscription subscription;
    subscription = getLoadingStatusStream(type).listen((status) {
      if (status.isLoaded && isDetectorCached(type)) {
        subscription.cancel();
        completer.complete(_detectorCache[type]);
      } else if (status.hasError) {
        subscription.cancel();
        completer.completeError(Exception(status.errorMessage));
      }
    });

    return completer.future;
  }

  void _updateStatus(
      PipelineType type,
      LoadingStatus status,
      void Function(LoadingStatus)? callback,
      ) {
    _loadingStatus[type] = status;
    _statusControllers[type]?.add(status);
    callback?.call(status);
  }

  /// Dispose a specific detector and remove from cache
  void disposeDetector(PipelineType type) {
    if (_detectorCache.containsKey(type)) {
      _detectorCache[type]!.dispose();
      _detectorCache.remove(type);
      _loadingStatus.remove(type);
    }
  }

  /// Dispose all cached detectors
  void disposeAll() {
    for (final detector in _detectorCache.values) {
      detector.dispose();
    }
    _detectorCache.clear();
    _loadingStatus.clear();

    for (final controller in _statusControllers.values) {
      controller.close();
    }
    _statusControllers.clear();
  }

  /// Get memory info (for debugging)
  Map<String, dynamic> getDebugInfo() {
    return {
      'cachedPipelines': _detectorCache.keys.map((e) => e.name).toList(),
      'loadingStates': _loadingStatus.map(
            (k, v) => MapEntry(k.name, v.state.name),
      ),
    };
  }
}