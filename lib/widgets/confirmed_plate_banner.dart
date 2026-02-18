import 'package:flutter/material.dart';

import '../services/plate_result_stabilizer.dart';

/// Animated banner shown when a plate is confirmed.
/// Slides up from bottom with success styling.
class ConfirmedPlateBanner extends StatefulWidget {
  final StabilizedPlateResult? result;

  const ConfirmedPlateBanner({
    super.key,
    this.result,
  });

  @override
  State<ConfirmedPlateBanner> createState() => _ConfirmedPlateBannerState();
}

class _ConfirmedPlateBannerState extends State<ConfirmedPlateBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _slideAnimation;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  StabilizedPlateResult? _displayedResult;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _slideAnimation = Tween<double>(begin: 50, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _scaleAnimation = Tween<double>(begin: 0.9, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );

    if (widget.result != null) {
      _displayedResult = widget.result;
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant ConfirmedPlateBanner oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.result != null &&
        widget.result!.fullPlate != _displayedResult?.fullPlate) {
      // New confirmed plate — animate in
      _displayedResult = widget.result;
      _controller.forward(from: 0);
    } else if (widget.result == null && _displayedResult != null) {
      // Lost detection — fade out
      _controller.reverse().then((_) {
        if (mounted) {
          setState(() {
            _displayedResult = null;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_displayedResult == null) return const SizedBox.shrink();

    final result = _displayedResult!;
    final isConfirmed = result.stability == PlateStability.confirmed;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _slideAnimation.value),
          child: Opacity(
            opacity: _fadeAnimation.value,
            child: Transform.scale(
              scale: _scaleAnimation.value,
              child: child,
            ),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: isConfirmed
              ? Colors.green.shade700.withOpacity(0.95)
              : Colors.blueGrey.shade700.withOpacity(0.9),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isConfirmed
                ? Colors.green.shade300
                : Colors.blueGrey.shade400,
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: (isConfirmed ? Colors.green : Colors.blueGrey)
                  .withOpacity(0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Status row
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isConfirmed ? Icons.check_circle : Icons.remove_red_eye,
                  color: Colors.white.withOpacity(0.8),
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  isConfirmed
                      ? 'CONFIRMED'
                      : 'DETECTING (${result.consecutiveFrames}/${RealtimeConfigHelper.confirmationCount})',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.8),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Plate text
            Text(
              result.fullPlate,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 6),

            // Details row
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (result.code.isNotEmpty) ...[
                  _chip('Code', result.code),
                  const SizedBox(width: 10),
                ],
                _chip('Number', result.number),
                const SizedBox(width: 10),
                _chip('Conf', '${(result.confidence * 100).toInt()}%'),
                const SizedBox(width: 10),
                _chip('Frames', '${result.consecutiveFrames}'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: TextStyle(
            color: Colors.white.withOpacity(0.5),
            fontSize: 11,
          ),
        ),
        Text(
          value.isEmpty ? '-' : value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}

/// Helper to avoid importing RealtimeConfig in widget
class RealtimeConfigHelper {
  static const int confirmationCount = 3; // Match RealtimeConfig value
}