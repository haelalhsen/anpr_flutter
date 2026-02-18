import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../config/realtime_config.dart';

// ══════════════════════════════════════════════════════════════
//  DATA TRANSFER OBJECT (for isolate communication)
// ══════════════════════════════════════════════════════════════

/// Serializable data extracted from CameraImage for isolate transfer.
///
/// CameraImage itself is not transferable across isolates because it
/// holds native plane references. We extract raw bytes on the main
/// isolate, then send this DTO to compute().
class _CameraFrameData {
  final int width;
  final int height;
  final int sensorOrientation;
  final int downsampleFactor;
  final bool isYUV;

  // YUV planes
  final Uint8List? yPlane;
  final Uint8List? uPlane;
  final Uint8List? vPlane;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;

  // BGRA plane
  final Uint8List? bgraPlane;
  final int bgraRowStride;

  _CameraFrameData({
    required this.width,
    required this.height,
    required this.sensorOrientation,
    required this.downsampleFactor,
    required this.isYUV,
    this.yPlane,
    this.uPlane,
    this.vPlane,
    this.yRowStride = 0,
    this.uvRowStride = 0,
    this.uvPixelStride = 1,
    this.bgraPlane,
    this.bgraRowStride = 0,
  });
}

// ══════════════════════════════════════════════════════════════
//  LOOKUP TABLES (pre-computed YUV→RGB coefficients)
// ══════════════════════════════════════════════════════════════

/// Pre-computed tables to avoid per-pixel floating point math.
/// BT.601 standard:
///   R = Y + 1.370705 * (V - 128)
///   G = Y - 0.337633 * (U - 128) - 0.698001 * (V - 128)
///   B = Y + 1.732446 * (U - 128)
class _YuvLookupTables {
  static final Int16List _vToR = _buildVtoR();
  static final Int16List _uToG = _buildUtoG();
  static final Int16List _vToG = _buildVtoG();
  static final Int16List _uToB = _buildUtoB();

  static bool _initialized = false;

  static Int16List _buildVtoR() {
    final table = Int16List(256);
    for (int i = 0; i < 256; i++) {
      table[i] = (1.370705 * (i - 128)).round();
    }
    return table;
  }

  static Int16List _buildUtoG() {
    final table = Int16List(256);
    for (int i = 0; i < 256; i++) {
      table[i] = (-0.337633 * (i - 128)).round();
    }
    return table;
  }

  static Int16List _buildVtoG() {
    final table = Int16List(256);
    for (int i = 0; i < 256; i++) {
      table[i] = (-0.698001 * (i - 128)).round();
    }
    return table;
  }

  static Int16List _buildUtoB() {
    final table = Int16List(256);
    for (int i = 0; i < 256; i++) {
      table[i] = (1.732446 * (i - 128)).round();
    }
    return table;
  }

  /// Ensure tables are initialized (they're lazy via static finals)
  static void ensureInitialized() {
    if (!_initialized) {
      // Access to trigger lazy init
      _vToR;
      _uToG;
      _vToG;
      _uToB;
      _initialized = true;
    }
  }

  static int vToR(int v) => _vToR[v];
  static int uToG(int u) => _uToG[u];
  static int vToG(int v) => _vToG[v];
  static int uToB(int u) => _uToB[u];
}

// ══════════════════════════════════════════════════════════════
//  OPTIMIZED CONVERTER
// ══════════════════════════════════════════════════════════════

class CameraImageConverterOptimized {
  // Prevent instantiation
  CameraImageConverterOptimized._();

  /// Initialize lookup tables eagerly (call once at startup)
  static void warmUp() {
    if (RealtimeConfig.useLookupTables) {
      _YuvLookupTables.ensureInitialized();
    }
  }

  /// Convert CameraImage using compute() isolate.
  ///
  /// Extracts raw bytes on main isolate (fast — just copying pointers),
  /// then offloads conversion + rotation to a background isolate.
  static Future<img.Image?> convertAsync(
      CameraImage cameraImage, {
        int sensorOrientation = 90,
        int downsampleFactor = RealtimeConfig.downsampleFactor,
      }) async {
    // Extract data on main isolate (must be done here — CameraImage
    // planes hold native pointers that expire after the callback)
    final frameData = _extractFrameData(
      cameraImage,
      sensorOrientation,
      downsampleFactor,
    );

    if (frameData == null) return null;

    if (RealtimeConfig.useIsolateConversion) {
      // Offload to background isolate
      return compute(_convertInIsolate, frameData);
    } else {
      // Run on main isolate
      return _convertInIsolate(frameData);
    }
  }

  /// Synchronous conversion (for cases where compute() overhead isn't worth it)
  static img.Image? convertSync(
      CameraImage cameraImage, {
        int sensorOrientation = 90,
        int downsampleFactor = RealtimeConfig.downsampleFactor,
      }) {
    final frameData = _extractFrameData(
      cameraImage,
      sensorOrientation,
      downsampleFactor,
    );

    if (frameData == null) return null;
    return _convertInIsolate(frameData);
  }

  /// Extract raw bytes from CameraImage into a transferable DTO.
  /// This MUST run on the main isolate while CameraImage is still valid.
  static _CameraFrameData? _extractFrameData(
      CameraImage image,
      int sensorOrientation,
      int downsampleFactor,
      ) {
    try {
      final isYUV = image.format.group == ImageFormatGroup.yuv420 ||
          (image.format.group != ImageFormatGroup.bgra8888 &&
              Platform.isAndroid);

      if (isYUV) {
        if (image.planes.length < 3) return null;

        return _CameraFrameData(
          width: image.width,
          height: image.height,
          sensorOrientation: sensorOrientation,
          downsampleFactor: downsampleFactor,
          isYUV: true,
          // Copy bytes — originals may be freed after callback
          yPlane: Uint8List.fromList(image.planes[0].bytes),
          uPlane: Uint8List.fromList(image.planes[1].bytes),
          vPlane: Uint8List.fromList(image.planes[2].bytes),
          yRowStride: image.planes[0].bytesPerRow,
          uvRowStride: image.planes[1].bytesPerRow,
          uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
        );
      } else {
        if (image.planes.isEmpty) return null;

        return _CameraFrameData(
          width: image.width,
          height: image.height,
          sensorOrientation: sensorOrientation,
          downsampleFactor: downsampleFactor,
          isYUV: false,
          bgraPlane: Uint8List.fromList(image.planes[0].bytes),
          bgraRowStride: image.planes[0].bytesPerRow,
        );
      }
    } catch (e) {
      return null;
    }
  }

  /// Top-level function for compute() — runs in background isolate.
  static img.Image? _convertInIsolate(_CameraFrameData data) {
    try {
      img.Image? result;

      if (data.isYUV) {
        result = _convertYUV420Optimized(data);
      } else {
        result = _convertBGRA8888Optimized(data);
      }

      if (result == null) return null;

      // Apply safety cap on dimensions
      result = _enforceMaxDimension(result);

      // Rotate
      if (data.sensorOrientation != 0) {
        result = img.copyRotate(result, angle: data.sensorOrientation);
      }

      return result;
    } catch (e) {
      return null;
    }
  }

  /// Optimized YUV420 conversion with lookup tables and direct pixel access.
  static img.Image? _convertYUV420Optimized(_CameraFrameData data) {
    final yBytes = data.yPlane;
    final uBytes = data.uPlane;
    final vBytes = data.vPlane;

    if (yBytes == null || uBytes == null || vBytes == null) return null;

    final ds = data.downsampleFactor;
    final outW = data.width ~/ ds;
    final outH = data.height ~/ ds;

    final yRowStride = data.yRowStride;
    final uvRowStride = data.uvRowStride;
    final uvPixelStride = data.uvPixelStride;

    final result = img.Image(width: outW, height: outH);

    // Ensure lookup tables are ready (they're static, but needed in isolate)
    _YuvLookupTables.ensureInitialized();

    for (int row = 0; row < outH; row++) {
      final srcY = row * ds;
      final yRowOffset = srcY * yRowStride;
      final uvRow = srcY >> 1;
      final uvRowOffset = uvRow * uvRowStride;

      for (int col = 0; col < outW; col++) {
        final srcX = col * ds;

        // Y value
        final y = yBytes[yRowOffset + srcX];

        // UV values
        final uvCol = srcX >> 1;
        final uvIdx = uvCol * uvPixelStride;
        final u = uBytes[uvRowOffset + uvIdx];
        final v = vBytes[uvRowOffset + uvIdx];

        // Lookup table conversion (no floating point per pixel)
        final r = (y + _YuvLookupTables.vToR(v)).clamp(0, 255);
        final g = (y + _YuvLookupTables.uToG(u) + _YuvLookupTables.vToG(v))
            .clamp(0, 255);
        final b = (y + _YuvLookupTables.uToB(u)).clamp(0, 255);

        result.setPixelRgb(col, row, r, g, b);
      }
    }

    return result;
  }

  /// Optimized BGRA conversion with stride-aware access.
  static img.Image? _convertBGRA8888Optimized(_CameraFrameData data) {
    final bytes = data.bgraPlane;
    if (bytes == null) return null;

    final ds = data.downsampleFactor;
    final outW = data.width ~/ ds;
    final outH = data.height ~/ ds;
    final rowStride = data.bgraRowStride;

    final result = img.Image(width: outW, height: outH);

    for (int row = 0; row < outH; row++) {
      final srcY = row * ds;
      final rowOffset = srcY * rowStride;

      for (int col = 0; col < outW; col++) {
        final srcX = col * ds;
        final idx = rowOffset + srcX * 4;

        // BGRA byte order
        result.setPixelRgb(col, row, bytes[idx + 2], bytes[idx + 1], bytes[idx]);
      }
    }

    return result;
  }

  /// Enforce maximum dimension cap as safety net.
  static img.Image _enforceMaxDimension(img.Image image) {
    final maxDim = RealtimeConfig.maxProcessingDimension;
    if (image.width <= maxDim && image.height <= maxDim) return image;

    final scale = maxDim / (image.width > image.height
        ? image.width
        : image.height);

    return img.copyResize(
      image,
      width: (image.width * scale).round(),
      height: (image.height * scale).round(),
      interpolation: img.Interpolation.nearest,
    );
  }
}