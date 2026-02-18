import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/license_plate_detector_metric_new.dart';

// ══════════════════════════════════════════════════════════════
//  COORDINATE MAPPING
// ══════════════════════════════════════════════════════════════

/// Maps detection box coordinates from processed image space
/// to camera preview display space, accounting for BoxFit.cover
class PreviewCoordinateMapper {
  // Prevent instantiation
  PreviewCoordinateMapper._();

  /// Map a DetectionBox from processed image coordinates
  /// to display widget coordinates.
  ///
  /// [box]                   — detection box in processed image space
  /// [processedImageWidth]   — width of image fed to recognizePlate()
  /// [processedImageHeight]  — height of image fed to recognizePlate()
  /// [displaySize]           — size of the preview widget on screen
  static Rect mapBoxToDisplay({
    required DetectionBox box,
    required double processedImageWidth,
    required double processedImageHeight,
    required Size displaySize,
  }) {
    if (processedImageWidth <= 0 || processedImageHeight <= 0) {
      return Rect.zero;
    }

    // Normalize to [0, 1] range
    final normX1 = box.x1 / processedImageWidth;
    final normY1 = box.y1 / processedImageHeight;
    final normX2 = box.x2 / processedImageWidth;
    final normY2 = box.y2 / processedImageHeight;

    // Calculate BoxFit.cover transform
    final imageAspect = processedImageWidth / processedImageHeight;
    final displayAspect = displaySize.width / displaySize.height;

    double scaledWidth, scaledHeight, offsetX, offsetY;

    if (displayAspect > imageAspect) {
      // Display is wider than image — image is cropped top/bottom
      scaledWidth = displaySize.width;
      scaledHeight = displaySize.width / imageAspect;
      offsetX = 0;
      offsetY = (displaySize.height - scaledHeight) / 2;
    } else {
      // Display is taller than image — image is cropped left/right
      scaledWidth = displaySize.height * imageAspect;
      scaledHeight = displaySize.height;
      offsetX = (displaySize.width - scaledWidth) / 2;
      offsetY = 0;
    }

    return Rect.fromLTRB(
      normX1 * scaledWidth + offsetX,
      normY1 * scaledHeight + offsetY,
      normX2 * scaledWidth + offsetX,
      normY2 * scaledHeight + offsetY,
    );
  }

  /// Map a single point from processed image space to display space
  static Offset mapPointToDisplay({
    required double x,
    required double y,
    required double processedImageWidth,
    required double processedImageHeight,
    required Size displaySize,
  }) {
    if (processedImageWidth <= 0 || processedImageHeight <= 0) {
      return Offset.zero;
    }

    final normX = x / processedImageWidth;
    final normY = y / processedImageHeight;

    final imageAspect = processedImageWidth / processedImageHeight;
    final displayAspect = displaySize.width / displaySize.height;

    double scaledWidth, scaledHeight, offsetX, offsetY;

    if (displayAspect > imageAspect) {
      scaledWidth = displaySize.width;
      scaledHeight = displaySize.width / imageAspect;
      offsetX = 0;
      offsetY = (displaySize.height - scaledHeight) / 2;
    } else {
      scaledWidth = displaySize.height * imageAspect;
      scaledHeight = displaySize.height;
      offsetX = (displaySize.width - scaledWidth) / 2;
      offsetY = 0;
    }

    return Offset(
      normX * scaledWidth + offsetX,
      normY * scaledHeight + offsetY,
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  BOUNDING BOX TRACKER (Smooth interpolation)
// ══════════════════════════════════════════════════════════════

/// Tracks bounding box state with smooth interpolation between frames
class _TrackedBox {
  Rect currentRect;
  Rect targetRect;
  double confidence;
  String? plateText;
  double opacity;
  double targetOpacity;

  _TrackedBox({
    required this.currentRect,
    required this.targetRect,
    required this.confidence,
    this.plateText,
    this.opacity = 0.0,
    this.targetOpacity = 1.0,
  });

  /// Interpolate toward target
  void lerp(double t) {
    currentRect = Rect.lerp(currentRect, targetRect, t) ?? targetRect;
    opacity = ui.lerpDouble(opacity, targetOpacity, t) ?? targetOpacity;
  }
}

// ══════════════════════════════════════════════════════════════
//  DETECTION OVERLAY WIDGET
// ══════════════════════════════════════════════════════════════

/// Animated overlay that draws bounding boxes on the camera preview.
///
/// Handles:
///  - Coordinate mapping from detection space → display space
///  - Smooth interpolation between frame results
///  - Fade in/out when detection appears/disappears
///  - Corner bracket style rendering
///  - Confidence and plate text labels
class DetectionOverlay extends StatefulWidget {
  /// Current detection result (null = no detection)
  final DetectionBox? detectionBox;

  /// Processed image dimensions (for coordinate mapping)
  final double processedImageWidth;
  final double processedImageHeight;

  /// Optional plate text to display near the box
  final String? plateText;

  /// Detection confidence (0.0 – 1.0)
  final double confidence;

  /// How many consecutive frames had no detection before clearing
  /// Prevents flickering when detection is intermittent
  final int staleFrameThreshold;

  const DetectionOverlay({
    super.key,
    this.detectionBox,
    required this.processedImageWidth,
    required this.processedImageHeight,
    this.plateText,
    this.confidence = 0.0,
    this.staleFrameThreshold = 3,
  });

  @override
  State<DetectionOverlay> createState() => _DetectionOverlayState();
}

class _DetectionOverlayState extends State<DetectionOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;

  _TrackedBox? _trackedBox;
  int _framesWithoutDetection = 0;

  // Interpolation speed: higher = snappier, lower = smoother
  static const double _lerpSpeed = 0.35;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 16), // ~60fps tick
    )..addListener(_onAnimationTick);
  }

  @override
  void didUpdateWidget(covariant DetectionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _onNewDetection();
  }

  void _onNewDetection() {
    if (widget.detectionBox != null) {
      _framesWithoutDetection = 0;
      _updateTrackedBox();
      _ensureAnimating();
    } else {
      _framesWithoutDetection++;
      if (_framesWithoutDetection >= widget.staleFrameThreshold) {
        _fadeOut();
      }
    }
  }

  void _updateTrackedBox() {
    // We need the display size — use the context if available
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;

    final displaySize = renderBox.size;

    final targetRect = PreviewCoordinateMapper.mapBoxToDisplay(
      box: widget.detectionBox!,
      processedImageWidth: widget.processedImageWidth,
      processedImageHeight: widget.processedImageHeight,
      displaySize: displaySize,
    );

    if (_trackedBox == null) {
      // First detection — appear at target
      _trackedBox = _TrackedBox(
        currentRect: targetRect,
        targetRect: targetRect,
        confidence: widget.confidence,
        plateText: widget.plateText,
        opacity: 0.0,
        targetOpacity: 1.0,
      );
    } else {
      // Update target for smooth interpolation
      _trackedBox!.targetRect = targetRect;
      _trackedBox!.targetOpacity = 1.0;
      _trackedBox!.confidence = widget.confidence;
      _trackedBox!.plateText = widget.plateText;
    }
  }

  void _fadeOut() {
    if (_trackedBox != null) {
      _trackedBox!.targetOpacity = 0.0;
      _ensureAnimating();
    }
  }

  void _ensureAnimating() {
    if (!_animController.isAnimating) {
      _animController.repeat();
    }
  }

  void _onAnimationTick() {
    if (_trackedBox == null) {
      _animController.stop();
      return;
    }

    _trackedBox!.lerp(_lerpSpeed);

    // Stop animating once fully faded out
    if (_trackedBox!.opacity < 0.01 && _trackedBox!.targetOpacity == 0.0) {
      _trackedBox = null;
      _animController.stop();
    }

    // Check convergence — stop ticking if close enough
    final box = _trackedBox;
    if (box != null) {
      final rectDiff = (box.currentRect.left - box.targetRect.left).abs() +
          (box.currentRect.top - box.targetRect.top).abs() +
          (box.currentRect.right - box.targetRect.right).abs() +
          (box.currentRect.bottom - box.targetRect.bottom).abs();
      final opacityDiff = (box.opacity - box.targetOpacity).abs();

      if (rectDiff < 0.5 && opacityDiff < 0.01) {
        box.currentRect = box.targetRect;
        box.opacity = box.targetOpacity;
        _animController.stop();
      }
    }

    setState(() {});
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DetectionOverlayPainter(
        trackedBox: _trackedBox,
      ),
      size: Size.infinite,
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  OVERLAY PAINTER
// ══════════════════════════════════════════════════════════════

class _DetectionOverlayPainter extends CustomPainter {
  final _TrackedBox? trackedBox;

  // Style constants
  static const double _cornerLength = 24.0;
  static const double _cornerThickness = 3.5;
  static const double _boxStrokeWidth = 1.5;
  static const double _cornerRadius = 6.0;
  static const double _labelFontSize = 13.0;
  static const double _labelPadding = 6.0;
  static const double _labelMarginBottom = 8.0;

  _DetectionOverlayPainter({this.trackedBox});

  @override
  void paint(Canvas canvas, Size size) {
    if (trackedBox == null || trackedBox!.opacity < 0.01) return;

    final box = trackedBox!;
    final rect = box.currentRect;
    final opacity = box.opacity;

    // ── Main box outline ─────────────────────────────────
    _drawBoxOutline(canvas, rect, opacity);

    // ── Corner brackets ──────────────────────────────────
    _drawCornerBrackets(canvas, rect, opacity);

    // ── Fill ─────────────────────────────────────────────
    _drawBoxFill(canvas, rect, opacity);

    // ── Confidence badge ─────────────────────────────────
    if (box.confidence > 0) {
      _drawConfidenceBadge(canvas, rect, box.confidence, opacity);
    }

    // ── Plate text label ─────────────────────────────────
    if (box.plateText != null && box.plateText!.isNotEmpty) {
      _drawPlateLabel(canvas, rect, box.plateText!, opacity, size);
    }
  }

  void _drawBoxOutline(Canvas canvas, Rect rect, double opacity) {
    final paint = Paint()
      ..color = Colors.green.withOpacity(0.6 * opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _boxStrokeWidth;

    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(_cornerRadius));
    canvas.drawRRect(rrect, paint);
  }

  void _drawCornerBrackets(Canvas canvas, Rect rect, double opacity) {
    final paint = Paint()
      ..color = Colors.green.withOpacity(opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _cornerThickness
      ..strokeCap = StrokeCap.round;

    final len = math.min(_cornerLength, math.min(rect.width, rect.height) / 3);

    // Top-left
    canvas.drawLine(
      Offset(rect.left, rect.top + len),
      Offset(rect.left, rect.top + _cornerRadius),
      paint,
    );
    canvas.drawArc(
      Rect.fromLTWH(rect.left, rect.top, _cornerRadius * 2, _cornerRadius * 2),
      math.pi, math.pi / 2, false, paint,
    );
    canvas.drawLine(
      Offset(rect.left + _cornerRadius, rect.top),
      Offset(rect.left + len, rect.top),
      paint,
    );

    // Top-right
    canvas.drawLine(
      Offset(rect.right - len, rect.top),
      Offset(rect.right - _cornerRadius, rect.top),
      paint,
    );
    canvas.drawArc(
      Rect.fromLTWH(rect.right - _cornerRadius * 2, rect.top, _cornerRadius * 2, _cornerRadius * 2),
      -math.pi / 2, math.pi / 2, false, paint,
    );
    canvas.drawLine(
      Offset(rect.right, rect.top + _cornerRadius),
      Offset(rect.right, rect.top + len),
      paint,
    );

    // Bottom-left
    canvas.drawLine(
      Offset(rect.left, rect.bottom - len),
      Offset(rect.left, rect.bottom - _cornerRadius),
      paint,
    );
    canvas.drawArc(
      Rect.fromLTWH(rect.left, rect.bottom - _cornerRadius * 2, _cornerRadius * 2, _cornerRadius * 2),
      math.pi / 2, math.pi / 2, false, paint,
    );
    canvas.drawLine(
      Offset(rect.left + _cornerRadius, rect.bottom),
      Offset(rect.left + len, rect.bottom),
      paint,
    );

    // Bottom-right
    canvas.drawLine(
      Offset(rect.right - len, rect.bottom),
      Offset(rect.right - _cornerRadius, rect.bottom),
      paint,
    );
    canvas.drawArc(
      Rect.fromLTWH(rect.right - _cornerRadius * 2, rect.bottom - _cornerRadius * 2, _cornerRadius * 2, _cornerRadius * 2),
      0, math.pi / 2, false, paint,
    );
    canvas.drawLine(
      Offset(rect.right, rect.bottom - _cornerRadius),
      Offset(rect.right, rect.bottom - len),
      paint,
    );
  }

  void _drawBoxFill(Canvas canvas, Rect rect, double opacity) {
    final paint = Paint()
      ..color = Colors.green.withOpacity(0.08 * opacity)
      ..style = PaintingStyle.fill;

    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(_cornerRadius));
    canvas.drawRRect(rrect, paint);
  }

  void _drawConfidenceBadge(
      Canvas canvas,
      Rect rect,
      double confidence,
      double opacity,
      ) {
    final text = '${(confidence * 100).toInt()}%';

    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white.withOpacity(opacity),
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final badgeWidth = textPainter.width + _labelPadding * 2;
    final badgeHeight = textPainter.height + _labelPadding;

    // Position at top-right corner of box
    final badgeRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        rect.right - badgeWidth,
        rect.top - badgeHeight - 4,
        badgeWidth,
        badgeHeight,
      ),
      const Radius.circular(4),
    );

    // Background
    final bgPaint = Paint()
      ..color = Colors.green.shade700.withOpacity(0.85 * opacity);
    canvas.drawRRect(badgeRect, bgPaint);

    // Text
    textPainter.paint(
      canvas,
      Offset(
        badgeRect.left + _labelPadding,
        badgeRect.top + _labelPadding / 2,
      ),
    );
  }

  void _drawPlateLabel(
      Canvas canvas,
      Rect rect,
      String plateText,
      double opacity,
      Size canvasSize,
      ) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: plateText,
        style: TextStyle(
          color: Colors.white.withOpacity(opacity),
          fontSize: _labelFontSize,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
          letterSpacing: 2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final labelWidth = textPainter.width + _labelPadding * 3;
    final labelHeight = textPainter.height + _labelPadding * 1.5;

    // Position centered below the box
    double labelX = rect.center.dx - labelWidth / 2;
    double labelY = rect.bottom + _labelMarginBottom;

    // Clamp to canvas bounds
    labelX = labelX.clamp(4.0, canvasSize.width - labelWidth - 4);
    labelY = labelY.clamp(4.0, canvasSize.height - labelHeight - 4);

    final labelRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(labelX, labelY, labelWidth, labelHeight),
      const Radius.circular(6),
    );

    // Background with border
    final bgPaint = Paint()
      ..color = Colors.black.withOpacity(0.7 * opacity);
    canvas.drawRRect(labelRect, bgPaint);

    final borderPaint = Paint()
      ..color = Colors.green.withOpacity(0.5 * opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRRect(labelRect, borderPaint);

    // Text
    textPainter.paint(
      canvas,
      Offset(
        labelX + _labelPadding * 1.5,
        labelY + _labelPadding * 0.75,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _DetectionOverlayPainter oldDelegate) {
    // Always repaint during animation
    return true;
  }
}

// ══════════════════════════════════════════════════════════════
//  SCANNING LINE EFFECT (Optional visual flair)
// ══════════════════════════════════════════════════════════════

/// Animated horizontal scanning line within the guide box area.
/// Purely cosmetic — indicates "actively scanning".
class ScanningLineOverlay extends StatefulWidget {
  final bool isActive;
  final Rect? guideRect;

  const ScanningLineOverlay({
    super.key,
    required this.isActive,
    this.guideRect,
  });

  @override
  State<ScanningLineOverlay> createState() => _ScanningLineOverlayState();
}

class _ScanningLineOverlayState extends State<ScanningLineOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    _animation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    if (widget.isActive) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant ScanningLineOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isActive && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isActive && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive || widget.guideRect == null) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return CustomPaint(
          painter: _ScanningLinePainter(
            progress: _animation.value,
            guideRect: widget.guideRect!,
          ),
          size: Size.infinite,
        );
      },
    );
  }
}

class _ScanningLinePainter extends CustomPainter {
  final double progress;
  final Rect guideRect;

  _ScanningLinePainter({required this.progress, required this.guideRect});

  @override
  void paint(Canvas canvas, Size size) {
    final y = guideRect.top + guideRect.height * progress;

    final paint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(guideRect.left, y),
        Offset(guideRect.right, y),
        [
          Colors.transparent,
          Colors.green.withOpacity(0.5),
          Colors.green.withOpacity(0.5),
          Colors.transparent,
        ],
        [0.0, 0.2, 0.8, 1.0],
      )
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      Offset(guideRect.left + 8, y),
      Offset(guideRect.right - 8, y),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ScanningLinePainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}