import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../config/realtime_config.dart';
import '../services/license_plate_detector_metric_new.dart';
import '../utils/image_conversion_optimized.dart';

/// Processing state for UI consumption
class ProcessingState {
  final LicensePlateResult? result;
  final double processingTimeMs;
  final double conversionTimeMs;
  final double inferenceTimeMs;
  final double fps;
  final bool isProcessing;
  final int framesProcessed;
  final int framesDropped;

  /// Dimensions of the image that was actually processed.
  /// Required for mapping detection boxes back to display coordinates.
  final double processedImageWidth;
  final double processedImageHeight;

  const ProcessingState({
    this.result,
    this.processingTimeMs = 0,
    this.conversionTimeMs = 0,
    this.inferenceTimeMs = 0,
    this.fps = 0,
    this.isProcessing = false,
    this.framesProcessed = 0,
    this.framesDropped = 0,
    this.processedImageWidth = 0,
    this.processedImageHeight = 0,
  });

  ProcessingState copyWith({
    LicensePlateResult? result,
    double? processingTimeMs,
    double? conversionTimeMs,
    double? inferenceTimeMs,
    double? fps,
    bool? isProcessing,
    int? framesProcessed,
    int? framesDropped,
    double? processedImageWidth,
    double? processedImageHeight,
  }) {
    return ProcessingState(
      result: result ?? this.result,
      processingTimeMs: processingTimeMs ?? this.processingTimeMs,
      conversionTimeMs: conversionTimeMs ?? this.conversionTimeMs,
      inferenceTimeMs: inferenceTimeMs ?? this.inferenceTimeMs,
      fps: fps ?? this.fps,
      isProcessing: isProcessing ?? this.isProcessing,
      framesProcessed: framesProcessed ?? this.framesProcessed,
      framesDropped: framesDropped ?? this.framesDropped,
      processedImageWidth: processedImageWidth ?? this.processedImageWidth,
      processedImageHeight: processedImageHeight ?? this.processedImageHeight,
    );
  }
}

/// Configuration for frame processing behavior
class FrameProcessorConfig {
  /// Sensor orientation from CameraDescription (typically 90 for back camera)
  final int sensorOrientation;

  /// Downsample factor for frame conversion (1=full, 2=half)
  final int downsampleFactor;

  /// Minimum interval between processing frames (ms)
  final int minIntervalMs;

  /// Use compute() isolate for image conversion
  final bool useIsolateConversion;

  const FrameProcessorConfig({
    this.sensorOrientation = 90,
    this.downsampleFactor = RealtimeConfig.downsampleFactor,
    this.minIntervalMs = RealtimeConfig.minFrameIntervalMs,
    this.useIsolateConversion = RealtimeConfig.useIsolateConversion,
  });
}

/// Processes camera frames through the LPR pipeline.
///
/// Architecture:
/// ```
/// Camera (30fps) → Frame Gate → [Isolate: Convert] → [Main: Inference] → UI
///                    ↓ (drop)
/// ```
///
/// Image conversion runs in a compute() isolate when enabled,
/// freeing ~50-100ms per frame from the main isolate.
/// TFLite inference must remain on main isolate (native pointers).
class CameraFrameProcessor {
  final LicensePlateDetectorMetricNew _detector;
  final FrameProcessorConfig config;

  // ── State ─────────────────────────────────────────────────
  bool _isActive = false;
  bool _isProcessing = false;
  bool _isDisposed = false;

  // ── Metrics ───────────────────────────────────────────────
  int _framesProcessed = 0;
  int _framesDropped = 0;
  int _lastProcessingEndTime = 0;

  // FPS sliding window
  final List<int> _frameCompletionTimes = [];
  static const int _fpsWindowSize = 10;

  // ── Last known processed image dimensions ─────────────────
  double _lastImageWidth = 0;
  double _lastImageHeight = 0;

  // ── Result retention ──────────────────────────────────────
  LicensePlateResult? _lastValidResult;
  int _lastValidResultTime = 0;

  // ── Callbacks ─────────────────────────────────────────────
  void Function(ProcessingState state)? onStateUpdate;
  void Function(String error)? onError;

  CameraFrameProcessor({
    required LicensePlateDetectorMetricNew detector,
    this.config = const FrameProcessorConfig(),
    this.onStateUpdate,
    this.onError,
  }) : _detector = detector;

  // ── Public Getters ────────────────────────────────────────

  bool get isActive => _isActive;
  bool get isProcessing => _isProcessing;
  int get framesProcessed => _framesProcessed;
  int get framesDropped => _framesDropped;

  double get currentFps {
    if (_frameCompletionTimes.length < 2) return 0;
    final oldest = _frameCompletionTimes.first;
    final newest = _frameCompletionTimes.last;
    final elapsedSeconds = (newest - oldest) / 1000000;
    if (elapsedSeconds <= 0) return 0;
    return (_frameCompletionTimes.length - 1) / elapsedSeconds;
  }

  // ── Lifecycle ─────────────────────────────────────────────

  void start() {
    if (_isDisposed) return;

    // Warm up lookup tables
    CameraImageConverterOptimized.warmUp();

    _isActive = true;
    _framesProcessed = 0;
    _framesDropped = 0;
    _frameCompletionTimes.clear();
    _lastProcessingEndTime = 0;
    _lastImageWidth = 0;
    _lastImageHeight = 0;
    _lastValidResult = null;
    _lastValidResultTime = 0;
  }

  void stop() {
    _isActive = false;
  }

  void dispose() {
    _isActive = false;
    _isDisposed = true;
    _frameCompletionTimes.clear();
    _lastValidResult = null;
    onStateUpdate = null;
    onError = null;
  }

  // ── Frame Handling ────────────────────────────────────────

  void processFrame(CameraImage cameraImage) {
    if (!_isActive || _isProcessing || _isDisposed) {
      _framesDropped++;
      return;
    }

    // Enforce minimum interval
    if (config.minIntervalMs > 0 && _lastProcessingEndTime > 0) {
      final now = DateTime.now().microsecondsSinceEpoch;
      final elapsed = (now - _lastProcessingEndTime) / 1000;
      if (elapsed < config.minIntervalMs) {
        _framesDropped++;
        return;
      }
    }

    _isProcessing = true;

    onStateUpdate?.call(ProcessingState(
      result: _getRetainedResult(),
      isProcessing: true,
      framesProcessed: _framesProcessed,
      framesDropped: _framesDropped,
      processedImageWidth: _lastImageWidth,
      processedImageHeight: _lastImageHeight,
    ));

    _processFrameInternal(cameraImage);
  }

  Future<void> _processFrameInternal(CameraImage cameraImage) async {
    final totalStart = DateTime.now().microsecondsSinceEpoch;

    try {
      // ── Step 1: Convert image (potentially in isolate) ────
      final conversionStart = DateTime.now().microsecondsSinceEpoch;

      final img.Image? convertedImage;

      if (config.useIsolateConversion) {
        convertedImage = await CameraImageConverterOptimized.convertAsync(
          cameraImage,
          sensorOrientation: config.sensorOrientation,
          downsampleFactor: config.downsampleFactor,
        );
      } else {
        convertedImage = CameraImageConverterOptimized.convertSync(
          cameraImage,
          sensorOrientation: config.sensorOrientation,
          downsampleFactor: config.downsampleFactor,
        );
      }

      final conversionTimeMs =
          (DateTime.now().microsecondsSinceEpoch - conversionStart) / 1000;

      if (convertedImage == null) {
        _finishFrame(
          totalStart: totalStart,
          conversionTimeMs: conversionTimeMs,
          inferenceTimeMs: 0,
          result: null,
          processedImage: null,
        );
        return;
      }

      // Guard: check if still active after conversion
      if (!_isActive || _isDisposed) {
        _isProcessing = false;
        return;
      }

      // Track image dimensions
      _lastImageWidth = convertedImage.width.toDouble();
      _lastImageHeight = convertedImage.height.toDouble();

      // ── Step 2: Run inference (must be main isolate) ──────
      final inferenceStart = DateTime.now().microsecondsSinceEpoch;

      final result = await _detector.recognizePlate(convertedImage);

      final inferenceTimeMs =
          (DateTime.now().microsecondsSinceEpoch - inferenceStart) / 1000;

      _finishFrame(
        totalStart: totalStart,
        conversionTimeMs: conversionTimeMs,
        inferenceTimeMs: inferenceTimeMs,
        result: result,
        processedImage: convertedImage,
      );
    } catch (e) {
      _isProcessing = false;
      _lastProcessingEndTime = DateTime.now().microsecondsSinceEpoch;
      onError?.call('Frame processing error: $e');
    }
  }

  void _finishFrame({
    required int totalStart,
    required double conversionTimeMs,
    required double inferenceTimeMs,
    required LicensePlateResult? result,
    required img.Image? processedImage,
  }) {
    final endTime = DateTime.now().microsecondsSinceEpoch;
    final totalMs = (endTime - totalStart) / 1000;

    _isProcessing = false;
    _lastProcessingEndTime = endTime;
    _framesProcessed++;

    // Update FPS window
    _frameCompletionTimes.add(endTime);
    if (_frameCompletionTimes.length > _fpsWindowSize) {
      _frameCompletionTimes.removeAt(0);
    }

    // Update result retention
    if (result != null) {
      _lastValidResult = result;
      _lastValidResultTime = endTime;
    }

    final imageWidth =
        processedImage?.width.toDouble() ?? _lastImageWidth;
    final imageHeight =
        processedImage?.height.toDouble() ?? _lastImageHeight;

    // Determine which result to show (current or retained)
    final displayResult = result ?? _getRetainedResult();

    if (!_isDisposed) {
      onStateUpdate?.call(ProcessingState(
        result: displayResult,
        processingTimeMs: totalMs,
        conversionTimeMs: conversionTimeMs,
        inferenceTimeMs: inferenceTimeMs,
        fps: currentFps,
        isProcessing: false,
        framesProcessed: _framesProcessed,
        framesDropped: _framesDropped,
        processedImageWidth: imageWidth,
        processedImageHeight: imageHeight,
      ));
    }
  }

  /// Returns the last valid result if within retention window.
  /// This prevents the result from flickering on/off when the plate
  /// briefly goes out of frame or one frame fails detection.
  LicensePlateResult? _getRetainedResult() {
    if (_lastValidResult == null) return null;

    final now = DateTime.now().microsecondsSinceEpoch;
    final elapsed = (now - _lastValidResultTime) / 1000; // ms

    if (elapsed <= RealtimeConfig.resultRetentionMs) {
      return _lastValidResult;
    }

    // Expired
    _lastValidResult = null;
    return null;
  }
}