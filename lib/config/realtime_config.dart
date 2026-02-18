/// Centralized tuning parameters for real-time LPR processing.
///
/// These are separated from the model pipeline config because they
/// control runtime behavior, not model selection.
class RealtimeConfig {
  // Prevent instantiation
  RealtimeConfig._();

  // ── Frame Conversion ────────────────────────────────────

  /// Downsample factor during YUV→RGB conversion.
  /// 2 = half resolution (720p → 360p). Since detection model input
  /// is 640×640, feeding ~640×360 loses no accuracy.
  static const int downsampleFactor = 1;

  /// Whether to use compute() isolate for image conversion.
  /// Offloads ~50-100ms of work off the main isolate.
  static const bool useIsolateConversion = true;

  // ── Detection Thresholds (real-time tuned) ──────────────

  /// Higher than static image (0.40) to reduce false positives
  /// on noisy/blurry live frames.
  static const double detectionConfidence = 0.50;

  /// Slightly higher for real-time to avoid phantom characters.
  static const double ocrConfidence = 0.20;

  // ── Frame Pacing ────────────────────────────────────────

  /// Minimum interval between frames (ms).
  /// 0 = process as fast as possible.
  /// Set to ~100ms to reduce thermal throttling on sustained use.
  /// /// 0 = process as fast as possible (~2.5 FPS at 400ms/frame).
  /// Set to 500 = max 2 FPS.
  /// Set to 200 = max 5 FPS (if inference is fast enough).
  static const int minFrameIntervalMs = 100;

  /// Maximum continuous processing duration before forced cooldown (seconds).
  /// 0 = no limit.
  static const int thermalCooldownAfterSeconds = 0;

  // ── Result Stability ────────────────────────────────────

  /// Number of consecutive identical results to consider "confirmed".
  static const int confirmationFrameCount = 3;

  /// Maximum time (ms) to keep showing last result after detection is lost.
  /// Prevents flickering when plate briefly goes out of frame.
  static const int resultRetentionMs = 800;

  /// Number of stale frames before clearing overlay bounding box.
  static const int staleFrameThreshold = 3;

  // ── Resolution ──────────────────────────────────────────

  /// Target max dimension for processing. Frames larger than this
  /// will be downscaled. This is enforced IN ADDITION to downsampleFactor
  /// as a safety cap.
  static const int maxProcessingDimension = 720;

  // ── YUV Conversion ──────────────────────────────────────

  /// Use pre-computed lookup tables for YUV→RGB conversion.
  /// Trades ~256KB memory for significant CPU reduction.
  static const bool useLookupTables = true;
}