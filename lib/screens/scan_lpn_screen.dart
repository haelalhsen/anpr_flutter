import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';

import '../config/pipeline_config.dart';
import '../config/realtime_config.dart';
import '../services/detection_only_processor.dart';
import '../services/license_plate_detector_metric_new.dart';
import '../services/model_service_manager.dart';
import '../widgets/detection_overlay.dart';
import '../widgets/loading_widgets.dart';
import '../widgets/scan_result_overlay.dart';

// ══════════════════════════════════════════════════════════════
//  PHASE
// ══════════════════════════════════════════════════════════════

enum ScanPhase {
  loading,
  scanning,
  capturing,
  recognizing,
  result,
  error,
}

// ══════════════════════════════════════════════════════════════
//  SCREEN
// ══════════════════════════════════════════════════════════════

class ScanLpnScreen extends StatefulWidget {
  final PipelineType pipelineType;
  final LicensePlateDetectorMetricNew? preloadedDetector;

  const ScanLpnScreen({
    super.key,
    required this.pipelineType,
    this.preloadedDetector,
  });

  @override
  State<ScanLpnScreen> createState() => _ScanLpnScreenState();
}

class _ScanLpnScreenState extends State<ScanLpnScreen>
    with WidgetsBindingObserver {
  // ── Camera ─────────────────────────────────────────────────
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraInitialized = false;
  bool _isTorchOn = false;
  int _sensorOrientation = 90;

  // ── Zoom ───────────────────────────────────────────────────
  double _currentZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _baseZoom = 1.0;

  // ── Model ──────────────────────────────────────────────────
  final ModelServiceManager _modelService = ModelServiceManager();
  LicensePlateDetectorMetricNew? _detector;
  double _loadingProgress = 0.0;
  String _loadingMessage = 'Initializing...';

  // ── Processor ──────────────────────────────────────────────
  DetectionOnlyProcessor? _processor;
  bool _isStreamActive = false;

  // ── Live overlay state ─────────────────────────────────────
  DetectionBox? _liveBox;
  double _liveW = 0;
  double _liveH = 0;
  int _stableCount = 0;
  int _requiredCount = 3;

  // ── Capture / result ───────────────────────────────────────
  CapturedFrame? _capturedFrame;
  LicensePlateResult? _ocrResult;
  Uint8List? _croppedBytes;
  bool _showFlash = false;

  // ── Phase ──────────────────────────────────────────────────
  ScanPhase _phase = ScanPhase.loading;

  // ── Guards ─────────────────────────────────────────────────
  bool _isNavigatingBack = false;
  bool _isDisposed = false;
  bool _permissionDenied = false;
  String? _errorMessage;
  bool _cameraInitializing = false;

  // ══════════════════════════════════════════════════════════
  //  LIFECYCLE
  // ══════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _processor?.dispose();
    _processor = null;
    _cameraController?.dispose();
    _cameraController = null;
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed || _isNavigatingBack) return;
    if (state == AppLifecycleState.inactive) {
      _stopStream();
      _disposeCameraController();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera().then((_) {
        if (_isCameraInitialized && _detector != null) _startScanning();
      });
    }
  }

  // ══════════════════════════════════════════════════════════
  //  INIT
  // ══════════════════════════════════════════════════════════

  Future<void> _initialize() async {
    await _requestPermission();
    if (_permissionDenied || _isDisposed) return;
    await Future.wait([_initializeCamera(), _initializeModel()]);
    if (!_isDisposed && _isCameraInitialized && _detector != null) {
      _startScanning();
    }
  }

  Future<void> _requestPermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    if (status.isDenied || status.isPermanentlyDenied) {
      setState(() {
        _permissionDenied = true;
        _phase = ScanPhase.error;
        _errorMessage = 'Camera permission required.';
      });
    }
  }

  Future<void> _initializeCamera() async {
    if (_cameraInitializing || _isDisposed) return;
    _cameraInitializing = true;
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        _setError('No cameras found on this device.');
        return;
      }
      final back = _cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );
      _sensorOrientation = back.sensorOrientation;

      final ctrl = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await ctrl.initialize();
      if (_isDisposed) {
        await ctrl.dispose();
        return;
      }
      _minZoom = await ctrl.getMinZoomLevel();
      _maxZoom = await ctrl.getMaxZoomLevel();
      _currentZoom = _minZoom;
      _cameraController = ctrl;
      if (mounted) setState(() => _isCameraInitialized = true);
    } catch (e) {
      _setError('Camera init failed: $e');
    } finally {
      _cameraInitializing = false;
    }
  }

  Future<void> _initializeModel() async {
    if (_isDisposed) return;
    if (widget.preloadedDetector != null) {
      _detector = widget.preloadedDetector;
      if (mounted) setState(() => _loadingProgress = 1.0);
      return;
    }
    try {
      if (mounted) setState(() { _loadingMessage = 'Loading models...'; _loadingProgress = 0.1; });
      await Future.delayed(const Duration(milliseconds: 50));
      _detector = await _modelService.getOrLoadDetector(
        widget.pipelineType,
        delegateType: DelegateType.gpu,
        onStatusChange: (s) {
          if (mounted && !_isDisposed) {
            setState(() {
              _loadingProgress = s.progress;
              _loadingMessage = s.progress < 0.5
                  ? 'Loading detection model...'
                  : s.progress < 0.9
                  ? 'Loading OCR model...'
                  : 'Finalizing...';
            });
          }
        },
      );
    } catch (e) {
      _setError('Model load failed: $e');
    }
  }

  void _setError(String msg) {
    if (mounted) setState(() { _phase = ScanPhase.error; _errorMessage = msg; });
  }

  // ══════════════════════════════════════════════════════════
  //  SCANNING
  // ══════════════════════════════════════════════════════════

  void _startScanning() {
    if (_detector == null || _cameraController == null || _isDisposed) return;
    if (_isStreamActive) return;

    _processor?.dispose();

    _processor = DetectionOnlyProcessor(
      detector: _detector!,
      sensorOrientation: _sensorOrientation,
      downsampleFactor: RealtimeConfig.downsampleFactor,
      minIntervalMs: RealtimeConfig.minFrameIntervalMs,
      qualityConfig: const CaptureQualityConfig(
        minConfidence: 0.70,
        requiredStableFrames: 3,
        maxCentreMoveFraction: 0.08,
        maxAreaChangeFraction: 0.06,
        minPlateAreaFraction: 0.005,
      ),
    );

    // Live overlay updates — only act when still in scanning phase
    _processor!.onFrameResult = (box, w, h, stable, required) {
      if (!mounted || _isDisposed || _phase != ScanPhase.scanning) return;
      setState(() {
        _liveBox = box;
        _liveW = w;
        _liveH = h;
        _stableCount = stable;
        _requiredCount = required;
      });
    };

    // Capture callback — the frame has already passed all gates.
    // We do NOT check _phase here because this callback is the event
    // that drives the phase transition FROM scanning → capturing.
    _processor!.onReadyToCapture = (CapturedFrame frame) {
      if (!mounted || _isDisposed) return;
      // Guard: only process the very first callback (processor sets
      // _captureTriggered=true so it won't fire again, but belt+braces)
      if (_phase != ScanPhase.scanning) return;
      _onCaptureReady(frame);
    };

    _processor!.onError = (e) => debugPrint('Processor error: $e');
    _processor!.start();

    _cameraController!.startImageStream(_processor!.processFrame);

    if (mounted) {
      setState(() {
        _phase = ScanPhase.scanning;
        _isStreamActive = true;
        _liveBox = null;
        _liveW = 0;
        _liveH = 0;
        _stableCount = 0;
        _capturedFrame = null;
        _ocrResult = null;
        _croppedBytes = null;
      });
    }
  }

  Future<void> _stopStream() async {
    _processor?.stop();
    try {
      if (_cameraController != null &&
          _cameraController!.value.isInitialized &&
          _cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
    } catch (e) {
      debugPrint('stopStream: $e');
    }
    if (mounted) setState(() => _isStreamActive = false);
  }

  // ══════════════════════════════════════════════════════════
  //  CAPTURE → OCR
  // ══════════════════════════════════════════════════════════

  /// Called by [DetectionOnlyProcessor.onReadyToCapture].
  /// The frame has already passed all quality gates.
  Future<void> _onCaptureReady(CapturedFrame frame) async {
    // Transition to capturing immediately — stops further callbacks acting
    setState(() {
      _phase = ScanPhase.capturing;
      _capturedFrame = frame;
      _showFlash = true;
    });

    // Stop the stream — no more frames needed.
    await _stopStream();

    // Flash widget will call _onFlashComplete via its onComplete callback.
  }

  void _onFlashComplete() {
    if (!mounted) return;
    setState(() => _showFlash = false);
    _runOcr();
  }

  Future<void> _runOcr() async {
    if (_capturedFrame == null || _detector == null) {
      _startScanning();
      return;
    }
    setState(() => _phase = ScanPhase.recognizing);

    try {
      final result = await _detector!.recognizePlate(_capturedFrame!.fullImage);

      if (!mounted) return;

      if (result == null || result.fullPlate.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not read plate — try again'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 2),
        ));
        _processor?.resetStability();
        _startScanning();
        return;
      }

      Uint8List? cropped;
      if (result.croppedPlate != null) {
        cropped = await compute(_encodePng, result.croppedPlate!);
      }

      if (mounted) {
        setState(() {
          _ocrResult = result;
          _croppedBytes = cropped;
          _phase = ScanPhase.result;
        });
      }
    } catch (e) {
      debugPrint('OCR error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Recognition error: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 2),
        ));
        _processor?.resetStability();
        _startScanning();
      }
    }
  }

  static Uint8List _encodePng(img.Image image) =>
      Uint8List.fromList(img.encodePng(image));

  // ══════════════════════════════════════════════════════════
  //  CAMERA CONTROLS
  // ══════════════════════════════════════════════════════════

  Future<void> _toggleTorch() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    try {
      await _cameraController!.setFlashMode(_isTorchOn ? FlashMode.off : FlashMode.torch);
      if (mounted) setState(() => _isTorchOn = !_isTorchOn);
    } catch (_) {}
  }

  void _onScaleStart(ScaleStartDetails d) => _baseZoom = _currentZoom;

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    final z = (_baseZoom * d.scale).clamp(_minZoom, _maxZoom);
    if ((z - _currentZoom).abs() > 0.01) {
      _currentZoom = z;
      _cameraController!.setZoomLevel(_currentZoom);
      setState(() {});
    }
  }

  Future<void> _onTapFocus(TapDownDetails d) async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    try {
      final s = MediaQuery.of(context).size;
      final p = Offset(d.localPosition.dx / s.width, d.localPosition.dy / s.height);
      await _cameraController!.setFocusPoint(p);
      await _cameraController!.setExposurePoint(p);
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════
  //  NAVIGATION
  // ══════════════════════════════════════════════════════════

  Future<void> _navigateBack() async {
    if (_isNavigatingBack) return;
    _isNavigatingBack = true;

    _processor?.stop();
    _processor?.dispose();
    _processor = null;

    try {
      if (_cameraController != null &&
          _cameraController!.value.isInitialized &&
          _cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
    } catch (_) {}

    try {
      if (_isTorchOn) await _cameraController?.setFlashMode(FlashMode.off);
    } catch (_) {}

    try { await _cameraController?.dispose(); } catch (_) {}

    _cameraController = null;
    _isDisposed = true;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _disposeCameraController() async {
    final ctrl = _cameraController;
    _cameraController = null;
    if (mounted) setState(() { _isCameraInitialized = false; _isTorchOn = false; });
    try {
      if (ctrl != null && ctrl.value.isInitialized) {
        if (ctrl.value.isStreamingImages) await ctrl.stopImageStream();
        await ctrl.dispose();
      }
    } catch (_) {}
  }

  // ══════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) _navigateBack(); },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_permissionDenied) return _buildPermissionDenied();
    if (_phase == ScanPhase.error) return _buildError();
    if (_phase == ScanPhase.loading) {
      return Stack(children: [
        if (_isCameraInitialized) _cameraPreview(),
        ModelLoadingOverlay(
          pipelineName: PipelineConfig.getConfig(widget.pipelineType).name,
          progress: _loadingProgress,
          statusMessage: _loadingMessage,
        ),
      ]);
    }
    return _buildMainView();
  }

  Widget _buildMainView() {
    return GestureDetector(
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onTapDown: _onTapFocus,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1 — camera preview
          _cameraPreview(),

          // 2 — frozen frame (capturing / recognizing / result)
          if (_capturedFrame != null &&
              (_phase == ScanPhase.capturing ||
                  _phase == ScanPhase.recognizing ||
                  _phase == ScanPhase.result))
            Positioned.fill(
              child: FrozenFrameView(
                capturedFrame: _capturedFrame!,
                animateBox: _phase == ScanPhase.recognizing,
              ),
            ),

          // 3 — live detection box (scanning only)
          if (_phase == ScanPhase.scanning && _liveW > 0 && _liveH > 0)
            Positioned.fill(
              child: DetectionOverlay(
                detectionBox: _liveBox,
                processedImageWidth: _liveW,
                processedImageHeight: _liveH,
                confidence: _liveBox?.confidence ?? 0,
                staleFrameThreshold: RealtimeConfig.staleFrameThreshold,
              ),
            ),

          // 4 — guide box (scanning only)
          if (_phase == ScanPhase.scanning) _buildGuide(),

          // 5 — capture flash
          if (_showFlash)
            CaptureFlashOverlay(onComplete: _onFlashComplete),

          // 6 — recognizing overlay
          if (_phase == ScanPhase.recognizing)
            const Positioned.fill(child: RecognizingOverlay()),

          // 7 — top bar
          _buildTopBar(),

          // 8 — bottom content
          if (_phase == ScanPhase.scanning) _buildScanningBottom(),
          if (_phase == ScanPhase.result) _buildResultPanel(),

          // 9 — zoom label
          if (_currentZoom > _minZoom + 0.1) _buildZoomLabel(),
        ],
      ),
    );
  }

  // ── Camera preview ────────────────────────────────────────

  Widget _cameraPreview() {
    final ctrl = _cameraController;
    if (ctrl == null || !ctrl.value.isInitialized) return const SizedBox.shrink();
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: ctrl.value.previewSize?.height ?? 0,
          height: ctrl.value.previewSize?.width ?? 0,
          child: CameraPreview(ctrl),
        ),
      ),
    );
  }

  // ── Guide box ─────────────────────────────────────────────

  Widget _buildGuide() {
    final hasBox = _liveBox != null;
    final locking = hasBox && _stableCount > 0;
    final t = _requiredCount > 0
        ? (_stableCount / _requiredCount).clamp(0.0, 1.0)
        : 0.0;
    final borderColor = locking
        ? Color.lerp(Colors.white.withOpacity(0.4), Colors.green.shade400, t)!
        : Colors.white.withOpacity(0.4);

    return Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: MediaQuery.of(context).size.width * 0.85,
        height: MediaQuery.of(context).size.width * 0.85 * 0.3,
        decoration: BoxDecoration(
          border: Border.all(color: borderColor, width: locking ? 2.5 : 2.0),
          borderRadius: BorderRadius.circular(8),
        ),
        child: !hasBox
            ? Center(
          child: Text(
            'Align plate here',
            style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 14),
          ),
        )
            : null,
      ),
    );
  }

  // ── Top bar ───────────────────────────────────────────────

  Widget _buildTopBar() {
    final titles = {
      ScanPhase.loading: 'Loading...',
      ScanPhase.scanning: 'Scan License Plate',
      ScanPhase.capturing: 'Capturing...',
      ScanPhase.recognizing: 'Reading Plate...',
      ScanPhase.result: 'Scan Result',
      ScanPhase.error: 'Error',
    };
    return Positioned(
      top: 0, left: 0, right: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withOpacity(0.6), Colors.transparent],
            ),
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: _navigateBack,
              ),
              Expanded(
                child: Text(
                  titles[_phase] ?? '',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ),
              if (_phase == ScanPhase.scanning)
                IconButton(
                  icon: Icon(
                    _isTorchOn ? Icons.flash_on : Icons.flash_off,
                    color: _isTorchOn ? Colors.amber : Colors.white,
                  ),
                  onPressed: _toggleTorch,
                )
              else
                const SizedBox(width: 48),
            ],
          ),
        ),
      ),
    );
  }

  // ── Scanning bottom ───────────────────────────────────────

  Widget _buildScanningBottom() {
    final hasBox = _liveBox != null;
    final locking = hasBox && _stableCount > 0;

    return Positioned(
      bottom: 0, left: 0, right: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.black.withOpacity(0.75),
                Colors.black.withOpacity(0.3),
                Colors.transparent,
              ],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Status row
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: locking
                    ? _lockingIndicator()
                    : hasBox
                    ? _detectedIndicator()
                    : _searchingIndicator(),
              ),

              // Stability bar (only when plate is detected)
              if (hasBox) ...[
                const SizedBox(height: 12),
                _stabilityBar(),
              ],

              const SizedBox(height: 12),

              // Status pill
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8, height: 8,
                      decoration: const BoxDecoration(
                          color: Colors.green, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    const Text('Hold steady — auto-capture enabled',
                        style: TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stabilityBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Stability',
                  style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 11)),
              Text('$_stableCount / $_requiredCount',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 11,
                      fontFamily: 'monospace')),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: List.generate(_requiredCount, (i) {
              return Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  height: 6,
                  decoration: BoxDecoration(
                    color: i < _stableCount
                        ? Colors.green.shade400
                        : Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _lockingIndicator() => Container(
    key: const ValueKey('locking'),
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.green.shade900.withOpacity(0.9),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.green.shade600),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 16, height: 16,
          child: CircularProgressIndicator(
            value: _requiredCount > 0 ? _stableCount / _requiredCount : 0,
            strokeWidth: 2.5,
            color: Colors.green.shade300,
            backgroundColor: Colors.white24,
          ),
        ),
        const SizedBox(width: 10),
        const Text('Locking on — hold still...',
            style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
      ],
    ),
  );

  Widget _detectedIndicator() => Container(
    key: const ValueKey('detected'),
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.blueGrey.shade800.withOpacity(0.85),
      borderRadius: BorderRadius.circular(12),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.crop_free, color: Colors.white70, size: 18),
        SizedBox(width: 8),
        Text('Plate detected — hold steady',
            style: TextStyle(color: Colors.white70, fontSize: 14)),
      ],
    ),
  );

  Widget _searchingIndicator() => Container(
    key: const ValueKey('searching'),
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.black.withOpacity(0.5),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 16, height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Colors.white.withOpacity(0.6)),
        ),
        const SizedBox(width: 10),
        Text('Point camera at a license plate',
            style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14)),
      ],
    ),
  );

  // ── Result panel ──────────────────────────────────────────

  Widget _buildResultPanel() {
    if (_ocrResult == null) return const SizedBox.shrink();
    return Positioned(
      bottom: 0, left: 0, right: 0,
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.52,
        child: ScanResultCard(
          result: _ocrResult!,
          croppedPlateBytes: _croppedBytes,
          onScanAgain: () => _startScanning(),
          onDone: _navigateBack,
        ),
      ),
    );
  }

  // ── Zoom label ────────────────────────────────────────────

  Widget _buildZoomLabel() => Positioned(
    top: 0, left: 0, right: 0,
    child: SafeArea(
      child: Center(
        child: Container(
          margin: const EdgeInsets.only(top: 56),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            '${_currentZoom.toStringAsFixed(1)}×',
            style: const TextStyle(
                color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    ),
  );

  // ── Permission denied ─────────────────────────────────────

  Widget _buildPermissionDenied() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.camera_alt_outlined, size: 64, color: Colors.white54),
          const SizedBox(height: 24),
          const Text('Camera Permission Required',
              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          const Text('Please grant camera access to scan license plates.',
              style: TextStyle(color: Colors.white70), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: openAppSettings,
            icon: const Icon(Icons.settings),
            label: const Text('Open Settings'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _navigateBack,
            child: const Text('Go Back', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    ),
  );

  // ── Error ─────────────────────────────────────────────────

  Widget _buildError() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 64, color: Colors.red.shade300),
          const SizedBox(height: 24),
          Text(_errorMessage ?? 'An error occurred',
              style: const TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () {
              setState(() { _phase = ScanPhase.loading; _errorMessage = null; _permissionDenied = false; });
              _initialize();
            },
            child: const Text('Retry'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _navigateBack,
            child: const Text('Go Back', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    ),
  );
}