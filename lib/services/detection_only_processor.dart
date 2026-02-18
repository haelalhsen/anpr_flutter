import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../config/realtime_config.dart';
import '../services/license_plate_detector_metric_new.dart';
import '../utils/image_conversion_optimized.dart';

// ══════════════════════════════════════════════════════════════
//  CAPTURED FRAME
// ══════════════════════════════════════════════════════════════

class CapturedFrame {
  final img.Image fullImage;
  final DetectionBox plateBox;

  double get width => fullImage.width.toDouble();
  double get height => fullImage.height.toDouble();

  const CapturedFrame({required this.fullImage, required this.plateBox});
}

// ══════════════════════════════════════════════════════════════
//  QUALITY CONFIG
// ══════════════════════════════════════════════════════════════

class CaptureQualityConfig {
  /// Minimum detection confidence per frame.
  final double minConfidence;

  /// How many consecutive frames must pass before capture fires.
  /// At 100 ms minInterval this is ~N × 0.1s of wall time PLUS
  /// inference time (~400 ms) per frame, so 3 frames ≈ 1.5 s total.
  final int requiredStableFrames;

  /// Max box-centre drift between frames as fraction of image WIDTH.
  /// 0.08 = 8% — loose enough for normal hand-held use.
  final double maxCentreMoveFraction;

  /// Max box-area change between frames as fraction of IMAGE area.
  /// 0.06 = 6% — allows slight zoom drift.
  final double maxAreaChangeFraction;

  /// Plate must cover at least this fraction of the image.
  /// 0.005 = 0.5% — very permissive; rejects only tiny far-away detections.
  final double minPlateAreaFraction;

  const CaptureQualityConfig({
    this.minConfidence = 0.55,
    this.requiredStableFrames = 3,
    this.maxCentreMoveFraction = 0.08,
    this.maxAreaChangeFraction = 0.06,
    this.minPlateAreaFraction = 0.005,
  });
}

// ══════════════════════════════════════════════════════════════
//  STABILITY TRACKER
// ══════════════════════════════════════════════════════════════

class _StabilityTracker {
  final CaptureQualityConfig cfg;

  int _stableCount = 0;
  DetectionBox? _prevBox;

  // Best candidate in the current stable run.
  img.Image? _bestImage;
  DetectionBox? _bestBox;
  double _bestConf = 0;

  _StabilityTracker(this.cfg);

  int get stableCount => _stableCount;
  int get requiredFrames => cfg.requiredStableFrames;

  /// Feed one processed frame. Returns [CapturedFrame] when all gates
  /// have been satisfied for [requiredStableFrames] consecutive frames,
  /// null on every other frame.
  CapturedFrame? feed({
    required DetectionBox? box,
    required img.Image image,
    required double imgW,
    required double imgH,
  }) {
    // Gate 1 — detection present + confidence
    if (box == null || box.confidence < cfg.minConfidence) {
      _softReset();
      return null;
    }

    // Gate 2 — plate not too small
    if (imgW > 0 && imgH > 0) {
      final plateFrac = (box.width * box.height) / (imgW * imgH);
      if (plateFrac < cfg.minPlateAreaFraction) {
        _softReset();
        return null;
      }
    }

    // Gate 3 — box stable vs previous frame
    if (_prevBox != null && imgW > 0) {
      final dx = (box.centerX - _prevBox!.centerX).abs() / imgW;
      final dy = (box.centerY - _prevBox!.centerY).abs() / imgW;
      if (dx + dy > cfg.maxCentreMoveFraction) {
        // Moving — update baseline but reset counter
        _prevBox = box;
        _clearRun();
        return null;
      }

      if (imgW > 0 && imgH > 0) {
        final imgArea = imgW * imgH;
        final areaDelta =
        (box.width * box.height - _prevBox!.width * _prevBox!.height).abs();
        if (areaDelta / imgArea > cfg.maxAreaChangeFraction) {
          _prevBox = box;
          _clearRun();
          return null;
        }
      }
    }

    // ── All gates passed ──────────────────────────────────
    _prevBox = box;
    _stableCount++;

    // Keep the highest-confidence frame as capture candidate
    if (box.confidence > _bestConf) {
      _bestConf = box.confidence;
      _bestImage = image;
      _bestBox = box;
    }

    if (_stableCount >= cfg.requiredStableFrames) {
      // Build result BEFORE reset so references are safe
      final frame = CapturedFrame(
        fullImage: _bestImage!,
        plateBox: _bestBox!,
      );
      _hardReset();
      return frame;
    }

    return null;
  }

  /// Full reset including previous-box baseline.
  void _hardReset() {
    _stableCount = 0;
    _prevBox = null;
    _clearRun();
  }

  /// Reset run counters but keep _prevBox so next frame has a baseline.
  void _softReset() {
    _prevBox = null; // no detection this frame — lose the baseline too
    _clearRun();
  }

  void _clearRun() {
    _stableCount = 0;
    _bestImage = null;
    _bestBox = null;
    _bestConf = 0;
  }

  // Public alias used by screen's resetStability()
  void reset() => _hardReset();

  void dispose() {
    _bestImage = null;
    _bestBox = null;
    _prevBox = null;
  }
}

// ══════════════════════════════════════════════════════════════
//  DETECTION ONLY PROCESSOR
// ══════════════════════════════════════════════════════════════

/// Processes live camera frames through detection only (OCR skipped).
///
/// Fires [onReadyToCapture] exactly once per scan cycle, only after
/// the plate has been detected with sufficient confidence AND the
/// bounding box has been stable for [requiredStableFrames] consecutive
/// processed frames.
///
/// Quality gates (all must pass on every frame in the stable run):
///   1. Detection present
///   2. Confidence ≥ minConfidence
///   3. Plate area ≥ minPlateAreaFraction of image
///   4. Box centre drift < maxCentreMoveFraction vs previous frame
///   5. Box area change < maxAreaChangeFraction vs previous frame
///   6. All above sustained for N consecutive frames
///
/// The [CapturedFrame] in [onReadyToCapture] contains the
/// highest-confidence frame from the stable run — not just the
/// triggering frame — giving OCR the best possible input.
class DetectionOnlyProcessor {
  final LicensePlateDetectorMetricNew _detector;
  final int sensorOrientation;
  final int downsampleFactor;
  final int minIntervalMs;
  final CaptureQualityConfig qualityConfig;

  bool _isActive = false;
  bool _isProcessing = false;
  bool _isDisposed = false;
  bool _captureTriggered = false;

  int _lastEndTime = 0;

  late _StabilityTracker _tracker;

  // ── Callbacks ─────────────────────────────────────────────

  /// Fires exactly once per scan cycle when all quality gates pass.
  /// [frame] is safe to pass directly to recognizePlate().
  void Function(CapturedFrame frame)? onReadyToCapture;

  /// Fires on every processed frame (detection result + stability progress).
  /// [stableCount] / [requiredCount] drive the progress indicator.
  void Function(
      DetectionBox? box,
      double imgW,
      double imgH,
      int stableCount,
      int requiredCount,
      )? onFrameResult;

  void Function(String error)? onError;

  // ── Constructor ───────────────────────────────────────────

  DetectionOnlyProcessor({
    required LicensePlateDetectorMetricNew detector,
    this.sensorOrientation = 90,
    this.downsampleFactor = RealtimeConfig.downsampleFactor,
    this.minIntervalMs = RealtimeConfig.minFrameIntervalMs,
    CaptureQualityConfig? qualityConfig,
  })  : _detector = detector,
        qualityConfig = qualityConfig ?? const CaptureQualityConfig() {
    _tracker = _StabilityTracker(this.qualityConfig);
  }

  // ── Public API ────────────────────────────────────────────

  bool get isActive => _isActive;

  void start() {
    if (_isDisposed) return;
    CameraImageConverterOptimized.warmUp();
    _tracker = _StabilityTracker(qualityConfig);
    _isActive = true;
    _isProcessing = false;
    _captureTriggered = false;
    _lastEndTime = 0;
  }

  void stop() => _isActive = false;

  /// Call this after a failed OCR so the stability tracker resets
  /// without needing to restart the whole camera stream.
  void resetStability() {
    _tracker.reset();
    _captureTriggered = false;
  }

  void processFrame(CameraImage cameraImage) {
    if (!_isActive || _isProcessing || _isDisposed || _captureTriggered) return;

    if (minIntervalMs > 0 && _lastEndTime > 0) {
      final elapsed =
          (DateTime.now().microsecondsSinceEpoch - _lastEndTime) / 1000;
      if (elapsed < minIntervalMs) return;
    }

    _isProcessing = true;
    _runPipeline(cameraImage);
  }

  void dispose() {
    _isActive = false;
    _isDisposed = true;
    _tracker.dispose();
    onReadyToCapture = null;
    onFrameResult = null;
    onError = null;
  }

  // ── Internal pipeline ─────────────────────────────────────

  Future<void> _runPipeline(CameraImage raw) async {
    try {
      // Step 1: YUV → RGB
      final img.Image? converted = RealtimeConfig.useIsolateConversion
          ? await CameraImageConverterOptimized.convertAsync(
        raw,
        sensorOrientation: sensorOrientation,
        downsampleFactor: downsampleFactor,
      )
          : CameraImageConverterOptimized.convertSync(
        raw,
        sensorOrientation: sensorOrientation,
        downsampleFactor: downsampleFactor,
      );

      if (converted == null || !_isActive || _isDisposed) {
        _isProcessing = false;
        _lastEndTime = DateTime.now().microsecondsSinceEpoch;
        return;
      }

      // Step 2: Detection (ignores OCR output)
      final result = await _detector.recognizePlate(converted);
      final box = result?.plateBox;

      final w = converted.width.toDouble();
      final h = converted.height.toDouble();

      // Step 3: Quality gates
      final captured = _tracker.feed(
        box: box,
        image: converted,
        imgW: w,
        imgH: h,
      );

      _isProcessing = false;
      _lastEndTime = DateTime.now().microsecondsSinceEpoch;

      if (_isDisposed) return;

      // Notify UI
      onFrameResult?.call(
        box,
        w,
        h,
        _tracker.stableCount,
        _tracker.requiredFrames,
      );

      // Fire capture exactly once
      if (captured != null && !_captureTriggered) {
        _captureTriggered = true;
        onReadyToCapture?.call(captured);
      }
    } catch (e) {
      _isProcessing = false;
      _lastEndTime = DateTime.now().microsecondsSinceEpoch;
      onError?.call('DetectionOnlyProcessor: $e');
    }
  }
}