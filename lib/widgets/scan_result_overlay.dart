import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../services/license_plate_detector_metric_new.dart';
import '../services/detection_only_processor.dart';

// ══════════════════════════════════════════════════════════════
//  FROZEN FRAME VIEW
// ══════════════════════════════════════════════════════════════

/// Displays a captured [img.Image] frame with a bounding box overlay.
///
/// Converts the image to PNG bytes once and caches them to avoid
/// repeated encoding on rebuilds. The bounding box is scaled from
/// image pixel coordinates to widget display coordinates, accounting
/// for [BoxFit.contain] letterboxing.
class FrozenFrameView extends StatefulWidget {
  final CapturedFrame capturedFrame;

  /// If true, draws an animated pulsing border around the plate box.
  final bool animateBox;

  const FrozenFrameView({
    super.key,
    required this.capturedFrame,
    this.animateBox = false,
  });

  @override
  State<FrozenFrameView> createState() => _FrozenFrameViewState();
}

class _FrozenFrameViewState extends State<FrozenFrameView>
    with SingleTickerProviderStateMixin {
  Uint8List? _imageBytes;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _encodeImage();
  }

  @override
  void didUpdateWidget(covariant FrozenFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.capturedFrame != widget.capturedFrame) {
      _encodeImage();
    }
  }

  /// Encode img.Image → PNG bytes off the main isolate to avoid jank.
  Future<void> _encodeImage() async {
    final bytes = await compute(
      _encodePng,
      widget.capturedFrame.fullImage,
    );
    if (mounted) {
      setState(() => _imageBytes = bytes);
    }
  }

  static Uint8List _encodePng(img.Image image) {
    return Uint8List.fromList(img.encodePng(image));
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_imageBytes == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          fit: StackFit.expand,
          children: [
            // ── Image ─────────────────────────────────────
            Image.memory(
              _imageBytes!,
              fit: BoxFit.contain,
              width: constraints.maxWidth,
              height: constraints.maxHeight,
            ),

            // ── Bounding box overlay ──────────────────────
            if (widget.animateBox)
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, _) => CustomPaint(
                  painter: _FrozenBoxPainter(
                    box: widget.capturedFrame.plateBox,
                    imageWidth: widget.capturedFrame.width,
                    imageHeight: widget.capturedFrame.height,
                    displaySize: Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    ),
                    opacity: _pulseAnimation.value,
                  ),
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                ),
              )
            else
              CustomPaint(
                painter: _FrozenBoxPainter(
                  box: widget.capturedFrame.plateBox,
                  imageWidth: widget.capturedFrame.width,
                  imageHeight: widget.capturedFrame.height,
                  displaySize: Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  ),
                  opacity: 1.0,
                ),
                size: Size(constraints.maxWidth, constraints.maxHeight),
              ),
          ],
        );
      },
    );
  }
}

// ── Painter ───────────────────────────────────────────────────

class _FrozenBoxPainter extends CustomPainter {
  final DetectionBox box;
  final double imageWidth;
  final double imageHeight;
  final Size displaySize;
  final double opacity;

  static const double _cornerLength = 22.0;
  static const double _cornerThickness = 3.5;
  static const double _cornerRadius = 5.0;

  _FrozenBoxPainter({
    required this.box,
    required this.imageWidth,
    required this.imageHeight,
    required this.displaySize,
    required this.opacity,
  });

  /// Maps a point from image coordinates to display coordinates,
  /// accounting for BoxFit.contain letterboxing (adds padding on short axis).
  Offset _map(double x, double y) {
    final imageAspect = imageWidth / imageHeight;
    final displayAspect = displaySize.width / displaySize.height;

    double scaledW, scaledH, offsetX, offsetY;

    if (displayAspect > imageAspect) {
      // Display wider → pillarbox (pad left/right)
      scaledH = displaySize.height;
      scaledW = scaledH * imageAspect;
      offsetX = (displaySize.width - scaledW) / 2;
      offsetY = 0;
    } else {
      // Display taller → letterbox (pad top/bottom)
      scaledW = displaySize.width;
      scaledH = scaledW / imageAspect;
      offsetX = 0;
      offsetY = (displaySize.height - scaledH) / 2;
    }

    return Offset(
      x / imageWidth * scaledW + offsetX,
      y / imageHeight * scaledH + offsetY,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final tl = _map(box.x1, box.y1);
    final br = _map(box.x2, box.y2);
    final rect = Rect.fromLTRB(tl.dx, tl.dy, br.dx, br.dy);

    // Semi-transparent fill
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.orange.withOpacity(0.12 * opacity)
        ..style = PaintingStyle.fill,
    );

    // Box outline
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(_cornerRadius)),
      Paint()
        ..color = Colors.orange.withOpacity(0.7 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Corner brackets
    _drawCorners(canvas, rect);
  }

  void _drawCorners(Canvas canvas, Rect rect) {
    final paint = Paint()
      ..color = Colors.orange.withOpacity(opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _cornerThickness
      ..strokeCap = StrokeCap.round;

    final len =
    math.min(_cornerLength, math.min(rect.width, rect.height) / 3);

    // Top-left
    canvas.drawLine(
        Offset(rect.left, rect.top + len), Offset(rect.left, rect.top), paint);
    canvas.drawLine(
        Offset(rect.left, rect.top), Offset(rect.left + len, rect.top), paint);

    // Top-right
    canvas.drawLine(Offset(rect.right - len, rect.top),
        Offset(rect.right, rect.top), paint);
    canvas.drawLine(
        Offset(rect.right, rect.top), Offset(rect.right, rect.top + len), paint);

    // Bottom-left
    canvas.drawLine(Offset(rect.left, rect.bottom - len),
        Offset(rect.left, rect.bottom), paint);
    canvas.drawLine(Offset(rect.left, rect.bottom),
        Offset(rect.left + len, rect.bottom), paint);

    // Bottom-right
    canvas.drawLine(Offset(rect.right - len, rect.bottom),
        Offset(rect.right, rect.bottom), paint);
    canvas.drawLine(Offset(rect.right, rect.bottom - len),
        Offset(rect.right, rect.bottom), paint);
  }

  @override
  bool shouldRepaint(covariant _FrozenBoxPainter old) =>
      old.opacity != opacity || old.box != box;
}

// ══════════════════════════════════════════════════════════════
//  SCAN RESULT CARD
// ══════════════════════════════════════════════════════════════

/// Displays the final OCR result after a plate has been captured and
/// processed. Mirrors the visual style of [LicensePlateScreenMetricNew].
///
/// Contains:
///  - Large plate text
///  - Cropped plate thumbnail
///  - Code / Number chips
///  - Metrics row
///  - "Scan Again" and "Done" action buttons
class ScanResultCard extends StatefulWidget {
  final LicensePlateResult result;

  /// PNG bytes of the cropped plate region (from [result.croppedPlate]).
  final Uint8List? croppedPlateBytes;

  final VoidCallback onScanAgain;
  final VoidCallback onDone;

  const ScanResultCard({
    super.key,
    required this.result,
    required this.croppedPlateBytes,
    required this.onScanAgain,
    required this.onDone,
  });

  @override
  State<ScanResultCard> createState() => _ScanResultCardState();
}

class _ScanResultCardState extends State<ScanResultCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
    ));

    _fadeAnimation = CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOut,
    );

    _slideController.forward();
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A1A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Drag handle ───────────────────────────
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Plate text ────────────────────────────
                _buildPlateText(),
                const SizedBox(height: 16),

                // ── Cropped thumbnail ─────────────────────
                if (widget.croppedPlateBytes != null)
                  _buildCroppedThumbnail(),

                const SizedBox(height: 16),

                // ── Metrics ───────────────────────────────
                _buildMetrics(),
                const SizedBox(height: 20),

                // ── Action buttons ────────────────────────
                _buildActions(),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlateText() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.green.shade800.withOpacity(0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.shade600, width: 1.5),
      ),
      child: Column(
        children: [
          // Status label
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle, color: Colors.green.shade400, size: 16),
              const SizedBox(width: 6),
              Text(
                'PLATE RECOGNIZED',
                style: TextStyle(
                  color: Colors.green.shade400,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Plate number — large monospace
          Text(
            widget.result.fullPlate,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
              letterSpacing: 5,
            ),
          ),
          const SizedBox(height: 10),

          // Code / Number chips
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.result.code.isNotEmpty) ...[
                _chip('Code', widget.result.code),
                const SizedBox(width: 12),
              ],
              _chip('Number', widget.result.number),
              if (widget.result.plateBox != null) ...[
                const SizedBox(width: 12),
                _chip(
                  'Conf',
                  '${(widget.result.plateBox!.confidence * 100).toInt()}%',
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          Text(
            value.isEmpty ? '—' : value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCroppedThumbnail() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CROPPED PLATE',
          style: TextStyle(
            color: Colors.white38,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white12),
            borderRadius: BorderRadius.circular(8),
            color: Colors.black38,
          ),
          constraints: const BoxConstraints(maxHeight: 80),
          width: double.infinity,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              widget.croppedPlateBytes!,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMetrics() {
    final m = widget.result.metrics;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.speed, color: Colors.white38, size: 14),
              const SizedBox(width: 6),
              Text(
                'PERFORMANCE',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _metricRow('Detection', m.detectionMs),
          _metricRow('Cropping', m.croppingMs),
          _metricRow('OCR', m.ocrMs),
          _metricRow('Logic', m.logicMs),
          const Divider(color: Colors.white12, height: 16),
          _metricRow('Total E2E', m.totalMs, isTotal: true),
        ],
      ),
    );
  }

  Widget _metricRow(String label, double ms, {bool isTotal = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isTotal ? Colors.white : Colors.white60,
              fontSize: isTotal ? 13 : 12,
              fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: isTotal
                  ? Colors.blue.shade900.withOpacity(0.5)
                  : Colors.white.withOpacity(0.07),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${ms.toStringAsFixed(1)} ms',
              style: TextStyle(
                color: isTotal ? Colors.blue.shade300 : Colors.white54,
                fontSize: 11,
                fontFamily: 'monospace',
                fontWeight:
                isTotal ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    return Row(
      children: [
        // Scan Again
        Expanded(
          child: OutlinedButton.icon(
            onPressed: widget.onScanAgain,
            icon: const Icon(Icons.refresh),
            label: const Text('Scan Again'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white24),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // Done
        Expanded(
          child: ElevatedButton.icon(
            onPressed: widget.onDone,
            icon: const Icon(Icons.check),
            label: const Text('Done'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade700,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  CAPTURE FLASH OVERLAY
// ══════════════════════════════════════════════════════════════

/// Brief white flash shown at the moment of frame capture.
/// Fades out over 300ms to mimic a camera shutter effect.
class CaptureFlashOverlay extends StatefulWidget {
  final VoidCallback onComplete;

  const CaptureFlashOverlay({super.key, required this.onComplete});

  @override
  State<CaptureFlashOverlay> createState() => _CaptureFlashOverlayState();
}

class _CaptureFlashOverlayState extends State<CaptureFlashOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _opacity = Tween<double>(begin: 0.6, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _controller.forward().then((_) => widget.onComplete());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _opacity,
      builder: (context, _) => Container(
        color: Colors.white.withOpacity(_opacity.value),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  RECOGNIZING OVERLAY
// ══════════════════════════════════════════════════════════════

/// Semi-transparent overlay shown while OCR is running on the frozen frame.
class RecognizingOverlay extends StatelessWidget {
  const RecognizingOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withOpacity(0.55),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(
                  color: Colors.orange,
                  strokeWidth: 3,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Reading plate...',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Running OCR pipeline',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}