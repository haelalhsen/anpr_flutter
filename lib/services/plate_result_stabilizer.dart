import 'dart:collection';

import 'package:flutter/services.dart';

import '../config/realtime_config.dart';
import '../services/license_plate_detector_metric_new.dart';

/// Stability state of a detected plate
enum PlateStability {
  /// Just detected, not yet confirmed
  detected,

  /// Same plate seen across multiple consecutive frames
  confirming,

  /// Confirmed — same plate seen N consecutive times
  confirmed,
}

/// A stabilized plate result with metadata
class StabilizedPlateResult {
  final String fullPlate;
  final String code;
  final String number;
  final double confidence;
  final PlateStability stability;
  final int consecutiveFrames;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final DetectionBox? plateBox;

  StabilizedPlateResult({
    required this.fullPlate,
    required this.code,
    required this.number,
    required this.confidence,
    required this.stability,
    required this.consecutiveFrames,
    required this.firstSeen,
    required this.lastSeen,
    this.plateBox,
  });

  StabilizedPlateResult copyWith({
    PlateStability? stability,
    int? consecutiveFrames,
    DateTime? lastSeen,
    double? confidence,
    DetectionBox? plateBox,
  }) {
    return StabilizedPlateResult(
      fullPlate: fullPlate,
      code: code,
      number: number,
      confidence: confidence ?? this.confidence,
      stability: stability ?? this.stability,
      consecutiveFrames: consecutiveFrames ?? this.consecutiveFrames,
      firstSeen: firstSeen,
      lastSeen: lastSeen ?? this.lastSeen,
      plateBox: plateBox ?? this.plateBox,
    );
  }
}

/// A historical plate detection entry
class PlateHistoryEntry {
  final String fullPlate;
  final String code;
  final String number;
  final double confidence;
  final DateTime timestamp;
  final int totalFramesSeen;

  PlateHistoryEntry({
    required this.fullPlate,
    required this.code,
    required this.number,
    required this.confidence,
    required this.timestamp,
    required this.totalFramesSeen,
  });
}

/// Stabilizes plate results across frames.
///
/// Handles:
///  - Tracking consecutive identical detections
///  - Confirming plates after N consecutive frames
///  - Triggering haptic feedback on confirmation
///  - Maintaining a detection history log
///  - Fuzzy matching for minor OCR inconsistencies
class PlateResultStabilizer {
  // ── Current tracking state ─────────────────────────────
  String? _currentPlateText;
  int _consecutiveCount = 0;
  DateTime? _firstSeen;
  double _bestConfidence = 0;
  DetectionBox? _lastBox;
  bool _hasConfirmedCurrent = false;

  // ── History ────────────────────────────────────────────
  final List<PlateHistoryEntry> _history = [];
  static const int _maxHistorySize = 50;

  // ── Configuration ──────────────────────────────────────
  final int confirmationThreshold;
  final bool enableHaptics;

  // ── Callbacks ──────────────────────────────────────────
  void Function(StabilizedPlateResult result)? onPlateConfirmed;
  void Function(PlateHistoryEntry entry)? onHistoryUpdated;

  PlateResultStabilizer({
    this.confirmationThreshold = RealtimeConfig.confirmationFrameCount,
    this.enableHaptics = true,
    this.onPlateConfirmed,
    this.onHistoryUpdated,
  });

  // ── Public Getters ─────────────────────────────────────

  List<PlateHistoryEntry> get history => UnmodifiableListView(_history);
  int get historyCount => _history.length;

  // ── Core Logic ─────────────────────────────────────────

  /// Process a new frame result. Returns a stabilized result
  /// with stability state information.
  StabilizedPlateResult? processResult(LicensePlateResult? result) {
    if (result == null) {
      // No detection — don't reset immediately (retention handled elsewhere)
      return null;
    }

    final plateText = _normalizePlate(result.fullPlate);

    if (plateText.isEmpty) return null;

    final now = DateTime.now();

    if (_isSamePlate(plateText, _currentPlateText)) {
      // Same plate — increment counter
      _consecutiveCount++;
      if (result.plateBox != null &&
          result.plateBox!.confidence > _bestConfidence) {
        _bestConfidence = result.plateBox!.confidence;
      }
      _lastBox = result.plateBox ?? _lastBox;
    } else {
      // New plate — reset tracking
      _currentPlateText = plateText;
      _consecutiveCount = 1;
      _firstSeen = now;
      _bestConfidence = result.plateBox?.confidence ?? 0;
      _lastBox = result.plateBox;
      _hasConfirmedCurrent = false;
    }

    // Determine stability
    PlateStability stability;
    if (_consecutiveCount >= confirmationThreshold) {
      stability = PlateStability.confirmed;

      // First time confirmed — trigger haptic and log
      if (!_hasConfirmedCurrent) {
        _hasConfirmedCurrent = true;
        _triggerConfirmation(result, now);
      }
    } else if (_consecutiveCount > 1) {
      stability = PlateStability.confirming;
    } else {
      stability = PlateStability.detected;
    }

    return StabilizedPlateResult(
      fullPlate: result.fullPlate,
      code: result.code,
      number: result.number,
      confidence: _bestConfidence,
      stability: stability,
      consecutiveFrames: _consecutiveCount,
      firstSeen: _firstSeen ?? now,
      lastSeen: now,
      plateBox: _lastBox,
    );
  }

  void _triggerConfirmation(LicensePlateResult result, DateTime now) {
    // Haptic feedback
    if (enableHaptics) {
      HapticFeedback.mediumImpact();
    }

    // Add to history (avoid duplicates within short window)
    _addToHistory(result, now);

    // Notify callback
    final stabilized = StabilizedPlateResult(
      fullPlate: result.fullPlate,
      code: result.code,
      number: result.number,
      confidence: _bestConfidence,
      stability: PlateStability.confirmed,
      consecutiveFrames: _consecutiveCount,
      firstSeen: _firstSeen ?? now,
      lastSeen: now,
      plateBox: _lastBox,
    );

    onPlateConfirmed?.call(stabilized);
  }

  void _addToHistory(LicensePlateResult result, DateTime now) {
    // Check if same plate was recently added (within 5 seconds)
    final normalized = _normalizePlate(result.fullPlate);
    if (_history.isNotEmpty) {
      final last = _history.last;
      final timeDiff = now.difference(last.timestamp).inSeconds;
      if (_isSamePlate(_normalizePlate(last.fullPlate), normalized) &&
          timeDiff < 5) {
        return; // Skip duplicate
      }
    }

    final entry = PlateHistoryEntry(
      fullPlate: result.fullPlate,
      code: result.code,
      number: result.number,
      confidence: _bestConfidence,
      timestamp: now,
      totalFramesSeen: _consecutiveCount,
    );

    _history.add(entry);
    if (_history.length > _maxHistorySize) {
      _history.removeAt(0);
    }

    onHistoryUpdated?.call(entry);
  }

  /// Normalize plate text for comparison (remove separators, case)
  String _normalizePlate(String text) {
    return text.replaceAll(RegExp(r'[^A-Z0-9]'), '').toUpperCase();
  }

  /// Fuzzy matching: allows 1 character difference for OCR jitter.
  bool _isSamePlate(String? a, String? b) {
    if (a == null || b == null) return false;
    if (a == b) return true;
    if ((a.length - b.length).abs() > 1) return false;

    // Allow 1 character difference (common OCR error between frames)
    if (a.length == b.length) {
      int diffs = 0;
      for (int i = 0; i < a.length; i++) {
        if (a[i] != b[i]) diffs++;
        if (diffs > 1) return false;
      }
      return true;
    }

    return false;
  }

  /// Reset current tracking (e.g., when user clears)
  void reset() {
    _currentPlateText = null;
    _consecutiveCount = 0;
    _firstSeen = null;
    _bestConfidence = 0;
    _lastBox = null;
    _hasConfirmedCurrent = false;
  }

  /// Clear all history
  void clearHistory() {
    _history.clear();
  }

  void dispose() {
    onPlateConfirmed = null;
    onHistoryUpdated = null;
  }
}