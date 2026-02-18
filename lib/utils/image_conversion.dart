import 'dart:io';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

/// Utility class for converting CameraImage to img.Image
/// Handles platform-specific formats:
///   - Android: YUV_420_888 (3 planes)
///   - iOS:     BGRA8888   (1 plane)
class CameraImageConverter {
  // Prevent instantiation
  CameraImageConverter._();

  /// Convert a CameraImage to img.Image
  ///
  /// [cameraImage]        — raw frame from camera stream
  /// [sensorOrientation]  — from CameraDescription.sensorOrientation (0, 90, 180, 270)
  /// [downsampleFactor]   — 1 = full resolution, 2 = half, etc.
  ///                        Since detection input is 640×640, downsampling a
  ///                        720p frame by 2 gives ~640×360 — ideal.
  static img.Image? convert(
      CameraImage cameraImage, {
        int sensorOrientation = 90,
        int downsampleFactor = 1,
      }) {
    try {
      img.Image? result;

      // Determine format from actual image metadata (most reliable)
      switch (cameraImage.format.group) {
        case ImageFormatGroup.yuv420:
          result = _convertYUV420(cameraImage, downsampleFactor);
          break;
        case ImageFormatGroup.bgra8888:
          result = _convertBGRA8888(cameraImage, downsampleFactor);
          break;
        default:
        // Platform-based fallback
          if (Platform.isAndroid) {
            result = _convertYUV420(cameraImage, downsampleFactor);
          } else if (Platform.isIOS) {
            result = _convertBGRA8888(cameraImage, downsampleFactor);
          }
      }

      if (result == null) return null;

      // Rotate to match device orientation (portrait up)
      // Most back cameras have sensorOrientation = 90
      if (sensorOrientation != 0) {
        result = img.copyRotate(result, angle: sensorOrientation);
      }

      return result;
    } catch (e) {
      // Silently fail — caller handles null
      return null;
    }
  }

  /// Convert YUV_420_888 format (Android)
  ///
  /// Handles both planar (pixelStride=1) and semi-planar (pixelStride=2)
  /// layouts. Downsampling is done during conversion to avoid allocating
  /// a full-size image first.
  static img.Image? _convertYUV420(CameraImage image, int ds) {
    if (image.planes.length < 3) return null;

    final int srcWidth = image.width;
    final int srcHeight = image.height;
    final int outW = srcWidth ~/ ds;
    final int outH = srcHeight ~/ ds;

    // Extract plane data
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final yBytes = yPlane.bytes;
    final uBytes = uPlane.bytes;
    final vBytes = vPlane.bytes;

    final int yRowStride = yPlane.bytesPerRow;
    final int uvRowStride = uPlane.bytesPerRow;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

    final result = img.Image(width: outW, height: outH);

    for (int row = 0; row < outH; row++) {
      final int srcY = row * ds;
      final int yRowOffset = srcY * yRowStride;
      final int uvRowOffset = (srcY >> 1) * uvRowStride;

      for (int col = 0; col < outW; col++) {
        final int srcX = col * ds;

        // Y value
        final int y = yBytes[yRowOffset + srcX];

        // UV values (subsampled by 2 in both dimensions)
        final int uvIndex = (srcX >> 1) * uvPixelStride;
        final int u = uBytes[uvRowOffset + uvIndex];
        final int v = vBytes[uvRowOffset + uvIndex];

        // YUV → RGB (BT.601 standard)
        final int r = (y + 1.370705 * (v - 128)).round().clamp(0, 255);
        final int g =
        (y - 0.337633 * (u - 128) - 0.698001 * (v - 128))
            .round()
            .clamp(0, 255);
        final int b = (y + 1.732446 * (u - 128)).round().clamp(0, 255);

        result.setPixelRgb(col, row, r, g, b);
      }
    }

    return result;
  }

  /// Convert BGRA8888 format (iOS)
  ///
  /// Single plane with 4 bytes per pixel: B, G, R, A
  static img.Image? _convertBGRA8888(CameraImage image, int ds) {
    if (image.planes.isEmpty) return null;

    final plane = image.planes[0];
    final int srcWidth = image.width;
    final int srcHeight = image.height;
    final int outW = srcWidth ~/ ds;
    final int outH = srcHeight ~/ ds;
    final int rowStride = plane.bytesPerRow;
    final bytes = plane.bytes;

    final result = img.Image(width: outW, height: outH);

    for (int row = 0; row < outH; row++) {
      final int srcY = row * ds;
      final int rowOffset = srcY * rowStride;

      for (int col = 0; col < outW; col++) {
        final int srcX = col * ds;
        final int idx = rowOffset + srcX * 4;

        // BGRA byte order
        final int b = bytes[idx];
        final int g = bytes[idx + 1];
        final int r = bytes[idx + 2];
        // skip alpha

        result.setPixelRgb(col, row, r, g, b);
      }
    }

    return result;
  }
}