import 'dart:typed_data';
import 'dart:math' as math;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:io' show Platform;
import 'dart:isolate';

/// Detection result with bounding box and confidence
class DetectionBox {
  final double x1, y1, x2, y2;
  final double confidence;
  final int classId;

  DetectionBox({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.confidence,
    required this.classId,
  });

  double get centerX => (x1 + x2) / 2;
  double get centerY => (y1 + y2) / 2;
  double get width => x2 - x1;
  double get height => y2 - y1;
}

/// Character detection with position
class CharDetection {
  final double x;
  final double y;
  final String char;
  final double confidence;

  CharDetection({
    required this.x,
    required this.y,
    required this.char,
    required this.confidence,
  });
}

/// Metrics for performance tracking
class InferenceMetrics {
  final double detectionMs;
  final double croppingMs;
  final double ocrMs;
  final double logicMs;
  final double totalMs;

  InferenceMetrics({
    required this.detectionMs,
    required this.croppingMs,
    required this.ocrMs,
    required this.logicMs,
    required this.totalMs,
  });

  Map<String, double> toMap() => {
    'detection_inference_ms': detectionMs,
    'cropping_post_proc_ms': croppingMs,
    'ocr_inference_ms': ocrMs,
    'logic_and_split_ms': logicMs,
    'total_e2e_ms': totalMs,
  };
  void printMetrics() {
    print('--- Inference Metrics ---');
    print('Detection: ${detectionMs.toStringAsFixed(2)} ms');
    print('Cropping : ${croppingMs.toStringAsFixed(2)} ms');
    print('OCR      : ${ocrMs.toStringAsFixed(2)} ms');
    print('Logic    : ${logicMs.toStringAsFixed(2)} ms');
    print('Total    : ${totalMs.toStringAsFixed(2)} ms');
    print('--------------------------');
  }
}

/// Final recognition result
class LicensePlateResult {
  final String code;
  final String number;
  final String fullPlate;
  final DetectionBox? plateBox;
  final InferenceMetrics metrics;
  final img.Image? croppedPlate;

  LicensePlateResult({
    required this.code,
    required this.number,
    required this.plateBox,
    required this.metrics,
    this.croppedPlate,
  }) : fullPlate = code.isNotEmpty ? '$code-$number' : number;
}

/// Helper class for letterbox result
class LetterboxResult {
  final img.Image image;
  final double ratio;
  final double padW;
  final double padH;

  LetterboxResult({
    required this.image,
    required this.ratio,
    required this.padW,
    required this.padH,
  });
}


enum DelegateType { cpu, gpu, nnapi, auto }

class LicensePlateDetectorMetricNew {
  Interpreter? _detInterpreter;
  Interpreter? _ocrInterpreter;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  int _detInputWidth = 640;
  int _detInputHeight = 640;
  int _ocrInputWidth = 160;
  int _ocrInputHeight = 160;

  // Pre-allocated buffers for reuse
  late Float32List _detInputBuffer;
  late Float32List _ocrInputBuffer;
  late List<List<List<double>>> _detOutputBuffer;
  late List<List<List<double>>> _ocrOutputBuffer;

  static const double detConfThreshold = 0.40;
  static const double ocrConfThreshold = 0.15;
  static const double iouThreshold = 0.45;
  static const double gapRatio = 1.8;
  static const double cropPadding = 0.05;

  static const Map<int, String> ocrClasses = {
    0: '0', 1: '1', 2: '2', 3: '3', 4: '4',
    5: '5', 6: '6', 7: '7', 8: '8', 9: '9',
    10: 'A', 11: 'B', 12: 'C', 13: 'D', 14: 'E',
    15: 'F', 16: 'G', 17: 'H', 18: 'I', 19: 'J',
    20: 'K', 21: 'L', 22: 'M', 23: 'N', 24: 'O',
    25: 'P', 26: 'Q', 27: 'R', 28: 'S', 29: 'T',
    30: 'U', 31: 'V', 32: 'W', 33: 'X', 34: 'Y',
    35: 'Z',
  };

  /// Initialize with automatic delegate selection
  Future<void> initialize({
    String detModelPath = 'assets/models/best_float32.tflite',
    String ocrModelPath = 'assets/models/ocr_model_float32.tflite',
    DelegateType delegateType = DelegateType.auto,
    int numThreads = 4,
  }) async {
    if (_isInitialized) return;

    try {
      final detOptions = await _createInterpreterOptions(delegateType, numThreads);
      final ocrOptions = await _createInterpreterOptions(delegateType, numThreads);

      _detInterpreter = await Interpreter.fromAsset(detModelPath, options: detOptions);
      _ocrInterpreter = await Interpreter.fromAsset(ocrModelPath, options: ocrOptions);

      _extractInputShapes();
      _preallocateBuffers();

      _isInitialized = true;
      print('LPR initialized successfully');
      print('Detection: $_detInputWidth x $_detInputHeight');
      print('OCR: $_ocrInputWidth x $_ocrInputHeight');
    } catch (e) {
      print('Initialization failed: $e');
      rethrow;
    }
  }

  Future<InterpreterOptions> _createInterpreterOptions(
      DelegateType type,
      int numThreads,
      ) async {
    final options = InterpreterOptions()..threads = numThreads;

    switch (type) {
      case DelegateType.gpu:
        _addGpuDelegate(options);
        break;
      case DelegateType.nnapi:
        if (Platform.isAndroid) {
          options.useNnApiForAndroid = true;
        } else {
          _addGpuDelegate(options);
        }
        break;
      case DelegateType.auto:
        if (Platform.isAndroid) {
          // Try NNAPI first on Android (often faster)
          options.useNnApiForAndroid = true;
        } else {
          _addGpuDelegate(options);
        }
        break;
      case DelegateType.cpu:
      // Just use threads, no delegate
        break;
    }

    return options;
  }

  void _addGpuDelegate(InterpreterOptions options) {
    try {
      final gpuDelegate = GpuDelegateV2(
        options: GpuDelegateOptionsV2(
          isPrecisionLossAllowed: true,
        ),
      );
      options.addDelegate(gpuDelegate);
    } catch (e) {
      print('GPU delegate not available: $e');
    }
  }

  void _extractInputShapes() {
    final detInputShape = _detInterpreter!.getInputTensor(0).shape;
    _detInputHeight = detInputShape[1];
    _detInputWidth = detInputShape[2];

    final ocrInputShape = _ocrInterpreter!.getInputTensor(0).shape;
    _ocrInputHeight = ocrInputShape[1];
    _ocrInputWidth = ocrInputShape[2];
  }

  void _preallocateBuffers() {
    // Pre-allocate input buffers
    _detInputBuffer = Float32List(_detInputWidth * _detInputHeight * 3);
    _ocrInputBuffer = Float32List(_ocrInputWidth * _ocrInputHeight * 3);

    // Pre-allocate output buffers
    final detOutputShape = _detInterpreter!.getOutputTensor(0).shape;
    _detOutputBuffer = List.generate(
      detOutputShape[0],
          (_) => List.generate(
        detOutputShape[1],
            (_) => List.filled(detOutputShape[2], 0.0),
      ),
    );

    final ocrOutputShape = _ocrInterpreter!.getOutputTensor(0).shape;
    _ocrOutputBuffer = List.generate(
      ocrOutputShape[0],
          (_) => List.generate(
        ocrOutputShape[1],
            (_) => List.filled(ocrOutputShape[2], 0.0),
      ),
    );
  }

  /// Main recognition pipeline - optimized
  Future<LicensePlateResult?> recognizePlate(img.Image image) async {
    if (!_isInitialized) {
      throw StateError('Detector not initialized');
    }

    final overallStart = DateTime.now().microsecondsSinceEpoch;
    final metrics = <String, double>{};

    // Step 1: Detection
    final detStart = DateTime.now().microsecondsSinceEpoch;
    final (detections, detRatio, detPadW, detPadH) = _runDetectionOptimized(image);
    metrics['detection'] = (DateTime.now().microsecondsSinceEpoch - detStart) / 1000;

    if (detections.isEmpty) return null;

    // Step 2: Crop
    final cropStart = DateTime.now().microsecondsSinceEpoch;
    final bestBox = _getBestDetection(detections);
    final croppedPlate = _cropPlate(image, bestBox);
    metrics['cropping'] = (DateTime.now().microsecondsSinceEpoch - cropStart) / 1000;

    // Step 3: OCR
    final ocrStart = DateTime.now().microsecondsSinceEpoch;
    final characters = _runOCROptimized(croppedPlate);
    metrics['ocr'] = (DateTime.now().microsecondsSinceEpoch - ocrStart) / 1000;

    // Step 4: Logic
    final logicStart = DateTime.now().microsecondsSinceEpoch;
    final (code, number) = characters.isEmpty
        ? ('', '')
        : _processCharacters(characters);
    metrics['logic'] = (DateTime.now().microsecondsSinceEpoch - logicStart) / 1000;

    final totalMs = (DateTime.now().microsecondsSinceEpoch - overallStart) / 1000;

    return LicensePlateResult(
      code: code,
      number: number,
      plateBox: bestBox,
      metrics: InferenceMetrics(
        detectionMs: metrics['detection']!,
        croppingMs: metrics['cropping']!,
        ocrMs: metrics['ocr']!,
        logicMs: metrics['logic']!,
        totalMs: totalMs,
      ),
      croppedPlate: croppedPlate,
    );
  }

  /// Optimized detection - reuses buffers
  (List<DetectionBox>, double, double, double) _runDetectionOptimized(img.Image image) {
    final origWidth = image.width.toDouble();
    final origHeight = image.height.toDouble();

    // Letterbox directly into pre-allocated buffer
    final (ratio, padW, padH) = _letterboxIntoBuffer(
      image,
      _detInputWidth,
      _detInputHeight,
      _detInputBuffer,
    );

    // Reset output buffer
    _resetOutputBuffer(_detOutputBuffer);

    // Run inference
    _detInterpreter!.run(_detInputBuffer.buffer.asUint8List(), _detOutputBuffer);

    // Parse results
    final detections = _parseDetectionsOptimized(
      _detOutputBuffer,
      ratio,
      padW,
      padH,
      origWidth,
      origHeight,
      detConfThreshold,
      _detInputWidth,
      _detInputHeight,
    );

    return (detections, ratio, padW, padH);
  }

  /// Optimized OCR - reuses buffers
  List<CharDetection> _runOCROptimized(img.Image plateImage) {
    final (ratio, padW, padH) = _letterboxIntoBuffer(
      plateImage,
      _ocrInputWidth,
      _ocrInputHeight,
      _ocrInputBuffer,
    );

    _resetOutputBuffer(_ocrOutputBuffer);

    _ocrInterpreter!.run(_ocrInputBuffer.buffer.asUint8List(), _ocrOutputBuffer);

    return _parseOCROptimized(
      _ocrOutputBuffer,
      ratio,
      padW,
      padH,
      ocrConfThreshold,
      _ocrInputWidth,
      _ocrInputHeight,
    );
  }

  /// Letterbox directly into target buffer (no allocations)
  (double, double, double) _letterboxIntoBuffer(
      img.Image image,
      int targetWidth,
      int targetHeight,
      Float32List buffer,
      ) {
    final srcWidth = image.width;
    final srcHeight = image.height;

    final ratio = math.min(
      targetWidth / srcWidth,
      targetHeight / srcHeight,
    );

    final newWidth = (srcWidth * ratio).round();
    final newHeight = (srcHeight * ratio).round();
    final padW = (targetWidth - newWidth) / 2;
    final padH = (targetHeight - newHeight) / 2;

    // Fill buffer with gray
    const grayNorm = 114.0 / 255.0;
    for (int i = 0; i < buffer.length; i++) {
      buffer[i] = grayNorm;
    }

    // Resize image (this is the bottleneck)
    final resized = img.copyResize(
      image,
      width: newWidth,
      height: newHeight,
      interpolation: img.Interpolation.nearest, // Faster
    );

    // Copy to buffer
    final padWInt = padW.round();
    final padHInt = padH.round();

    for (int y = 0; y < newHeight; y++) {
      final outY = y + padHInt;
      final rowOffset = outY * targetWidth;

      for (int x = 0; x < newWidth; x++) {
        final pixel = resized.getPixel(x, y);
        final outX = x + padWInt;
        final idx = (rowOffset + outX) * 3;

        buffer[idx] = pixel.r / 255.0;
        buffer[idx + 1] = pixel.g / 255.0;
        buffer[idx + 2] = pixel.b / 255.0;
      }
    }

    return (ratio, padW, padH);
  }

  void _resetOutputBuffer(List<List<List<double>>> buffer) {
    for (var batch in buffer) {
      for (var row in batch) {
        for (int i = 0; i < row.length; i++) {
          row[i] = 0.0;
        }
      }
    }
  }

  List<DetectionBox> _parseDetectionsOptimized(
      List<List<List<double>>> output,
      double ratio,
      double padW,
      double padH,
      double origWidth,
      double origHeight,
      double confThreshold,
      int inputWidth,
      int inputHeight,
      ) {
    final boxes = <DetectionBox>[];
    final scores = <double>[];
    final rawBoxes = <List<double>>[];

    final data = output[0];
    final numOutputs = data.length;
    final numDetections = data[0].length;

    final isNormalized = data[0][0] <= 2.0;

    for (int i = 0; i < numDetections; i++) {
      double x = data[0][i];
      double y = data[1][i];
      double w = data[2][i];
      double h = data[3][i];

      double maxScore = 0;
      int maxClassId = 0;
      for (int c = 4; c < numOutputs; c++) {
        final score = data[c][i];
        if (score > maxScore) {
          maxScore = score;
          maxClassId = c - 4;
        }
      }

      if (maxScore < confThreshold) continue;

      if (isNormalized) {
        x *= inputWidth;
        y *= inputHeight;
        w *= inputWidth;
        h *= inputHeight;
      }

      x = (x - padW) / ratio;
      y = (y - padH) / ratio;
      w /= ratio;
      h /= ratio;

      final x1 = (x - w / 2).clamp(0.0, origWidth);
      final y1 = (y - h / 2).clamp(0.0, origHeight);
      final x2 = (x + w / 2).clamp(0.0, origWidth);
      final y2 = (y + h / 2).clamp(0.0, origHeight);

      rawBoxes.add([x1, y1, x2, y2]);
      scores.add(maxScore);
      boxes.add(DetectionBox(
        x1: x1, y1: y1, x2: x2, y2: y2,
        confidence: maxScore,
        classId: maxClassId,
      ));
    }

    if (boxes.isEmpty) return [];
    final keepIndices = _nms(rawBoxes, scores, iouThreshold);
    return keepIndices.map((i) => boxes[i]).toList();
  }

  List<CharDetection> _parseOCROptimized(
      List<List<List<double>>> output,
      double ratio,
      double padW,
      double padH,
      double confThreshold,
      int inputWidth,
      int inputHeight,
      ) {
    final chars = <CharDetection>[];
    final boxes = <List<double>>[];
    final scores = <double>[];

    final data = output[0];
    final numOutputs = data.length;
    final numDetections = data[0].length;

    final isNormalized = data[0][0] <= 2.0;

    for (int i = 0; i < numDetections; i++) {
      double x = data[0][i];
      double y = data[1][i];
      double w = data[2][i];
      double h = data[3][i];

      double maxScore = 0;
      int maxClassId = 0;
      for (int c = 4; c < numOutputs; c++) {
        final score = data[c][i];
        if (score > maxScore) {
          maxScore = score;
          maxClassId = c - 4;
        }
      }

      if (maxScore < confThreshold) continue;

      if (isNormalized) {
        x *= inputWidth;
        y *= inputHeight;
        w *= inputWidth;
        h *= inputHeight;
      }

      x = (x - padW) / ratio;
      y = (y - padH) / ratio;

      final charStr = ocrClasses[maxClassId] ?? '?';

      boxes.add([x - w / 2, y - h / 2, x + w / 2, y + h / 2]);
      scores.add(maxScore);
      chars.add(CharDetection(
        x: x, y: y,
        char: charStr,
        confidence: maxScore,
      ));
    }

    if (chars.isEmpty) return [];
    final keepIndices = _nms(boxes, scores, iouThreshold);
    return keepIndices.map((i) => chars[i]).toList();
  }

  // Keep existing helper methods: _nms, _calculateIoU, _getBestDetection,
  // _cropPlate, _processCharacters, _splitLettersNumbers, _splitByGap

  List<int> _nms(List<List<double>> boxes, List<double> scores, double iouThresh) {
    if (boxes.isEmpty) return [];

    final indices = List.generate(boxes.length, (i) => i);
    indices.sort((a, b) => scores[b].compareTo(scores[a]));

    final keep = <int>[];
    final suppressed = List.filled(boxes.length, false);

    for (final i in indices) {
      if (suppressed[i]) continue;
      keep.add(i);

      for (final j in indices) {
        if (i == j || suppressed[j]) continue;
        if (_calculateIoU(boxes[i], boxes[j]) > iouThresh) {
          suppressed[j] = true;
        }
      }
    }

    return keep;
  }

  double _calculateIoU(List<double> boxA, List<double> boxB) {
    final x1 = math.max(boxA[0], boxB[0]);
    final y1 = math.max(boxA[1], boxB[1]);
    final x2 = math.min(boxA[2], boxB[2]);
    final y2 = math.min(boxA[3], boxB[3]);

    final intersection = math.max(0, x2 - x1) * math.max(0, y2 - y1);
    final areaA = (boxA[2] - boxA[0]) * (boxA[3] - boxA[1]);
    final areaB = (boxB[2] - boxB[0]) * (boxB[3] - boxB[1]);
    final union = areaA + areaB - intersection;

    return union > 0 ? intersection / union : 0;
  }

  DetectionBox _getBestDetection(List<DetectionBox> detections) {
    return detections.reduce((a, b) => a.confidence > b.confidence ? a : b);
  }

  img.Image _cropPlate(img.Image image, DetectionBox box) {
    final padW = (box.width * cropPadding).round();
    final padH = (box.height * cropPadding).round();

    final x1 = (box.x1 - padW).clamp(0, image.width - 1).round();
    final y1 = (box.y1 - padH).clamp(0, image.height - 1).round();
    final x2 = (box.x2 + padW).clamp(0, image.width).round();
    final y2 = (box.y2 + padH).clamp(0, image.height).round();

    return img.copyCrop(image, x: x1, y: y1, width: x2 - x1, height: y2 - y1);
  }

  (String, String) _processCharacters(List<CharDetection> chars) {
    final sorted = List<CharDetection>.from(chars)..sort((a, b) => a.x.compareTo(b.x));
    final plateText = sorted.map((c) => c.char).join();
    final hasLetters = sorted.any((c) => c.char.contains(RegExp(r'[A-Z]')));

    return hasLetters ? _splitLettersNumbers(plateText) : _splitByGap(sorted);
  }

  (String, String) _splitLettersNumbers(String text) {
    final letters = text.replaceAll(RegExp(r'[^A-Z]'), '');
    final numbers = text.replaceAll(RegExp(r'[^0-9]'), '');
    return (letters, numbers);
  }

  (String, String) _splitByGap(List<CharDetection> chars) {
    if (chars.length < 2) return ('', chars.map((c) => c.char).join());

    final gaps = <double>[];
    for (int i = 0; i < chars.length - 1; i++) {
      gaps.add(chars[i + 1].x - chars[i].x);
    }

    final avgGap = gaps.reduce((a, b) => a + b) / gaps.length;
    final maxGap = gaps.reduce(math.max);
    final maxGapIndex = gaps.indexOf(maxGap);

    if (maxGap < avgGap * gapRatio) {
      return ('', chars.map((c) => c.char).join());
    }

    final code = chars.sublist(0, maxGapIndex + 1).map((c) => c.char).join();
    final number = chars.sublist(maxGapIndex + 1).map((c) => c.char).join();
    return (code, number);
  }

  void dispose() {
    _detInterpreter?.close();
    _ocrInterpreter?.close();
    _isInitialized = false;
  }
}
