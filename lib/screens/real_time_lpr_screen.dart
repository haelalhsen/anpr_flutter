import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/pipeline_config.dart';
import '../config/realtime_config.dart';
import '../services/license_plate_detector_metric_new.dart';
import '../services/model_service_manager.dart';
import '../services/camera_frame_processor.dart';
import '../services/plate_result_stabilizer.dart';
import '../utils/image_conversion_optimized.dart';
import '../widgets/loading_widgets.dart';
import '../widgets/detection_overlay.dart';
import '../widgets/confirmed_plate_banner.dart';
import '../widgets/plate_history_sheet.dart';

class RealTimeLprScreen extends StatefulWidget {
  final PipelineType pipelineType;
  final LicensePlateDetectorMetricNew? preloadedDetector;

  const RealTimeLprScreen({
    super.key,
    required this.pipelineType,
    this.preloadedDetector,
  });

  @override
  State<RealTimeLprScreen> createState() => _RealTimeLprScreenState();
}

class _RealTimeLprScreenState extends State<RealTimeLprScreen>
    with WidgetsBindingObserver {
  // ── Camera ──────────────────────────────────────────────
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraInitialized = false;
  bool _isTorchOn = false;
  int _sensorOrientation = 90;

  // ── Zoom ────────────────────────────────────────────────
  double _currentZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _baseZoom = 1.0;

  // ── Model ───────────────────────────────────────────────
  final ModelServiceManager _modelService = ModelServiceManager();
  LicensePlateDetectorMetricNew? _detector;
  bool _isModelLoaded = false;
  double _loadingProgress = 0.0;
  String _loadingMessage = 'Initializing...';

  // ── Frame Processing ────────────────────────────────────
  CameraFrameProcessor? _frameProcessor;
  bool _isStreamActive = false;
  ProcessingState _processingState = const ProcessingState();

  // ── Stabilizer ──────────────────────────────────────────
  late PlateResultStabilizer _stabilizer;
  StabilizedPlateResult? _stabilizedResult;

  // ── Guide Overlay Rect ──────────────────────────────────
  Rect? _guideRect;
  final GlobalKey _guideKey = GlobalKey();

  // ── State ───────────────────────────────────────────────
  String? _errorMessage;
  bool _permissionDenied = false;
  bool _isDisposed = false;
  bool _isCameraBeingInitialized = false;
  bool _isNavigatingBack = false;
  bool _showMetrics = true;

  // ══════════════════════════════════════════════════════════
  //  INIT / DISPOSE
  // ══════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);

    _stabilizer = PlateResultStabilizer(
      confirmationThreshold: RealtimeConfig.confirmationFrameCount,
      enableHaptics: true,
      onPlateConfirmed: _onPlateConfirmed,
    );

    CameraImageConverterOptimized.warmUp();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialize();
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);

    _frameProcessor?.dispose();
    _frameProcessor = null;

    _stabilizer.dispose();

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

  // ══════════════════════════════════════════════════════════
  //  INITIALIZATION
  // ══════════════════════════════════════════════════════════

  Future<void> _initialize() async {
    await _requestCameraPermission();
    if (_permissionDenied || _isDisposed) return;

    await Future.wait([
      _initializeCamera(),
      _initializeModel(),
    ]);

    _tryStartProcessing();
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;

    if (status.isDenied || status.isPermanentlyDenied) {
      setState(() {
        _permissionDenied = true;
        _errorMessage =
        'Camera permission is required for real-time detection';
      });
    }
  }

  Future<void> _initializeCamera() async {
    if (_isCameraBeingInitialized || _isDisposed) return;
    _isCameraBeingInitialized = true;

    try {
      _cameras = await availableCameras();

      if (_cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _errorMessage = 'No cameras available on this device';
          });
        }
        return;
      }

      final backCamera = _cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      _sensorOrientation = backCamera.sensorOrientation;

      final controller = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await controller.initialize();

      if (_isDisposed) {
        await controller.dispose();
        return;
      }

      _minZoom = await controller.getMinZoomLevel();
      _maxZoom = await controller.getMaxZoomLevel();
      _currentZoom = _minZoom;

      _cameraController = controller;

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to initialize camera: $e';
        });
      }
    } finally {
      _isCameraBeingInitialized = false;
    }
  }

  Future<void> _initializeModel() async {
    if (_isDisposed) return;

    if (widget.preloadedDetector != null) {
      _detector = widget.preloadedDetector;
      if (mounted) {
        setState(() {
          _isModelLoaded = true;
          _loadingProgress = 1.0;
        });
      }
      return;
    }

    try {
      if (mounted) {
        setState(() {
          _loadingMessage = 'Loading detection model...';
          _loadingProgress = 0.1;
        });
      }

      await Future.delayed(const Duration(milliseconds: 50));

      _detector = await _modelService.getOrLoadDetector(
        widget.pipelineType,
        delegateType: DelegateType.gpu,
        onStatusChange: (status) {
          if (mounted && !_isDisposed) {
            setState(() {
              _loadingProgress = status.progress;
              if (status.progress < 0.5) {
                _loadingMessage = 'Loading detection model...';
              } else if (status.progress < 0.9) {
                _loadingMessage = 'Loading OCR model...';
              } else {
                _loadingMessage = 'Finalizing...';
              }
            });
          }
        },
      );

      if (mounted && !_isDisposed) {
        setState(() {
          _isModelLoaded = true;
        });
      }
    } catch (e) {
      if (mounted && !_isDisposed) {
        setState(() {
          _errorMessage = 'Failed to load models: $e';
        });
      }
    }
  }

  // ══════════════════════════════════════════════════════════
  //  FRAME PROCESSING
  // ══════════════════════════════════════════════════════════

  void _tryStartProcessing() {
    if (!_isCameraInitialized || !_isModelLoaded || _isDisposed) return;
    if (_detector == null || _cameraController == null) return;
    if (_isStreamActive) return;

    _startProcessing();
  }

  void _startProcessing() {
    if (_detector == null || _cameraController == null) return;

    _frameProcessor = CameraFrameProcessor(
      detector: _detector!,
      config: FrameProcessorConfig(
        sensorOrientation: _sensorOrientation,
        downsampleFactor: RealtimeConfig.downsampleFactor,
        minIntervalMs: RealtimeConfig.minFrameIntervalMs,
        useIsolateConversion: RealtimeConfig.useIsolateConversion,
      ),
      onStateUpdate: _onProcessingStateUpdate,
      onError: _onProcessingError,
    );

    _frameProcessor!.start();

    _cameraController!.startImageStream((CameraImage image) {
      _frameProcessor?.processFrame(image);
    });

    if (mounted) {
      setState(() {
        _isStreamActive = true;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateGuideRect();
      });
    }
  }

  Future<void> _stopProcessing() async {
    _frameProcessor?.stop();

    try {
      if (_cameraController != null &&
          _cameraController!.value.isInitialized &&
          _cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
    } catch (e) {
      debugPrint('Error stopping image stream: $e');
    }

    if (mounted) {
      setState(() {
        _isStreamActive = false;
      });
    }
  }

  void _onProcessingStateUpdate(ProcessingState state) {
    if (!mounted || _isDisposed) return;

    final stabilized = _stabilizer.processResult(state.result);

    setState(() {
      _processingState = state;
      if (stabilized != null) {
        _stabilizedResult = stabilized;
      }
    });
  }

  void _onPlateConfirmed(StabilizedPlateResult result) {
    debugPrint(
        '✅ CONFIRMED: ${result.fullPlate} (${result.consecutiveFrames} frames)');
  }

  void _onProcessingError(String error) {
    debugPrint('Frame processing error: $error');
  }

  void _updateGuideRect() {
    final renderBox =
    _guideKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      final position = renderBox.localToGlobal(Offset.zero);
      setState(() {
        _guideRect = position & renderBox.size;
      });
    }
  }

  // ══════════════════════════════════════════════════════════
  //  CAMERA CONTROLS
  // ══════════════════════════════════════════════════════════

  Future<void> _toggleTorch() async {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized) return;

    try {
      if (_isTorchOn) {
        await _cameraController!.setFlashMode(FlashMode.off);
      } else {
        await _cameraController!.setFlashMode(FlashMode.torch);
      }
      if (mounted) {
        setState(() {
          _isTorchOn = !_isTorchOn;
        });
      }
    } catch (e) {
      debugPrint('Torch toggle failed: $e');
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _baseZoom = _currentZoom;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized) return;

    final newZoom = (_baseZoom * details.scale).clamp(_minZoom, _maxZoom);

    if ((newZoom - _currentZoom).abs() > 0.01) {
      _currentZoom = newZoom;
      _cameraController!.setZoomLevel(_currentZoom);
      setState(() {});
    }
  }

  Future<void> _onTapToFocus(TapDownDetails details) async {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized) return;

    try {
      final size = MediaQuery.of(context).size;
      final point = Offset(
        details.localPosition.dx / size.width,
        details.localPosition.dy / size.height,
      );
      await _cameraController!.setFocusPoint(point);
      await _cameraController!.setExposurePoint(point);
    } catch (e) {
      debugPrint('Focus failed: $e');
    }
  }

  // ══════════════════════════════════════════════════════════
  //  SAFE NAVIGATION BACK
  // ══════════════════════════════════════════════════════════

  Future<void> _navigateBack() async {
    if (_isNavigatingBack) return;
    _isNavigatingBack = true;

    _frameProcessor?.stop();
    _frameProcessor?.dispose();
    _frameProcessor = null;

    try {
      if (_cameraController != null &&
          _cameraController!.value.isInitialized &&
          _cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
    } catch (e) {
      debugPrint('Error stopping stream on back: $e');
    }

    try {
      if (_isTorchOn && _cameraController != null) {
        await _cameraController!.setFlashMode(FlashMode.off);
      }
    } catch (_) {}

    try {
      await _cameraController?.dispose();
    } catch (e) {
      debugPrint('Error disposing camera on back: $e');
    }

    _cameraController = null;
    _isDisposed = true;

    if (mounted) {
      Navigator.pop(context);
    }
  }

  // ══════════════════════════════════════════════════════════
  //  LIFECYCLE
  // ══════════════════════════════════════════════════════════

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed || _isNavigatingBack) return;

    switch (state) {
      case AppLifecycleState.inactive:
        _handleInactive();
        break;
      case AppLifecycleState.resumed:
        _handleResumed();
        break;
      default:
        break;
    }
  }

  Future<void> _handleInactive() async {
    await _stopProcessing();
    await _disposeCameraController();
  }

  Future<void> _handleResumed() async {
    if (_isDisposed || _isNavigatingBack) return;
    await _initializeCamera();
    _tryStartProcessing();
  }

  Future<void> _disposeCameraController() async {
    final controller = _cameraController;
    _cameraController = null;

    if (mounted) {
      setState(() {
        _isCameraInitialized = false;
        _isTorchOn = false;
      });
    }

    try {
      if (controller != null && controller.value.isInitialized) {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
        await controller.dispose();
      }
    } catch (e) {
      debugPrint('Error disposing camera controller: $e');
    }
  }

  // ══════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _navigateBack();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_permissionDenied) return _buildPermissionDenied();
    if (_errorMessage != null && !_isCameraInitialized) return _buildError();
    if (!_isModelLoaded) return _buildLoadingState();
    if (!_isCameraInitialized) return _buildCameraLoading();
    return _buildMainView();
  }

  // ── Loading States ────────────────────────────────────────

  Widget _buildLoadingState() {
    final config = PipelineConfig.getConfig(widget.pipelineType);

    return Stack(
      children: [
        if (_isCameraInitialized) _buildCameraPreview(),
        ModelLoadingOverlay(
          pipelineName: config.name,
          progress: _loadingProgress,
          statusMessage: _loadingMessage,
        ),
      ],
    );
  }

  Widget _buildCameraLoading() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 16),
          Text('Starting camera...', style: TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  // ── Main View ─────────────────────────────────────────────

  Widget _buildMainView() {
    final hasDetection = _processingState.result != null;
    final noDetection = _isStreamActive && !hasDetection;

    return GestureDetector(
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onTapDown: _onTapToFocus,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Layer 1: Camera preview
          _buildCameraPreview(),

          // Layer 2: Detection bounding box overlay
          if (_processingState.processedImageWidth > 0 &&
              _processingState.processedImageHeight > 0)
            Positioned.fill(
              child: DetectionOverlay(
                detectionBox: _processingState.result?.plateBox,
                processedImageWidth: _processingState.processedImageWidth,
                processedImageHeight: _processingState.processedImageHeight,
                plateText: _processingState.result?.fullPlate,
                confidence:
                _processingState.result?.plateBox?.confidence ?? 0,
                staleFrameThreshold: RealtimeConfig.staleFrameThreshold,
              ),
            ),

          // Layer 3: Scanning line
          ScanningLineOverlay(
            isActive: noDetection,
            guideRect: _guideRect,
          ),

          // Layer 4: Guide overlay box
          _buildGuideOverlay(),

          // Layer 5: Top bar
          _buildTopBar(),

          // Layer 6: Bottom result bar
          _buildBottomResultBar(),

          // Layer 7: Metrics overlay
          if (_showMetrics) _buildMetricsOverlay(),

          // Layer 8: Zoom indicator
          if (_currentZoom > _minZoom + 0.1) _buildZoomIndicator(),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }

    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: controller.value.previewSize?.height ?? 0,
          height: controller.value.previewSize?.width ?? 0,
          child: CameraPreview(controller),
        ),
      ),
    );
  }

  // ── Top Bar ───────────────────────────────────────────────

  Widget _buildTopBar() {
    final historyCount = _stabilizer.historyCount;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withOpacity(0.6),
                Colors.transparent,
              ],
            ),
          ),
          child: Row(
            children: [
              // Back
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: _navigateBack,
              ),

              // Title
              const Expanded(
                child: Text(
                  'Real-Time LPR',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),

              // History button with badge
              Stack(
                children: [
                  IconButton(
                    icon: const Icon(Icons.history, color: Colors.white),
                    onPressed: () => PlateHistorySheet.show(
                      context,
                      history: _stabilizer.history,
                      onClear: () {
                        _stabilizer.clearHistory();
                        setState(() {});
                      },
                    ),
                    tooltip: 'Detection history',
                  ),
                  if (historyCount > 0)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 18,
                          minHeight: 18,
                        ),
                        child: Text(
                          '$historyCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              ),

              // Metrics toggle
              IconButton(
                icon: Icon(
                  _showMetrics ? Icons.speed : Icons.speed_outlined,
                  color: _showMetrics ? Colors.amber : Colors.white54,
                  size: 22,
                ),
                onPressed: () => setState(() => _showMetrics = !_showMetrics),
                tooltip: 'Toggle metrics',
                visualDensity: VisualDensity.compact,
              ),

              // Torch
              IconButton(
                icon: Icon(
                  _isTorchOn ? Icons.flash_on : Icons.flash_off,
                  color: _isTorchOn ? Colors.amber : Colors.white,
                ),
                onPressed: _toggleTorch,
                tooltip: 'Toggle flashlight',
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Guide Overlay ─────────────────────────────────────────

  Widget _buildGuideOverlay() {
    final isConfirmed =
        _stabilizedResult?.stability == PlateStability.confirmed;
    final hasDetection = _processingState.result != null;

    final Color borderColor;
    final double borderWidth;

    if (isConfirmed) {
      borderColor = Colors.green.withOpacity(0.9);
      borderWidth = 3.5;
    } else if (hasDetection) {
      borderColor = Colors.green.withOpacity(0.6);
      borderWidth = 2.5;
    } else {
      borderColor = Colors.white.withOpacity(0.4);
      borderWidth = 2.0;
    }

    return Center(
      child: AnimatedContainer(
        key: _guideKey,
        duration: const Duration(milliseconds: 200),
        width: MediaQuery.of(context).size.width * 0.85,
        height: MediaQuery.of(context).size.width * 0.85 * 0.3,
        decoration: BoxDecoration(
          border: Border.all(color: borderColor, width: borderWidth),
          borderRadius: BorderRadius.circular(8),
        ),
        child: !hasDetection
            ? Center(
          child: Text(
            'Align plate here',
            style: TextStyle(
              color: Colors.white.withOpacity(0.4),
              fontSize: 14,
            ),
          ),
        )
            : null,
      ),
    );
  }

  // ── Zoom Indicator ────────────────────────────────────────

  Widget _buildZoomIndicator() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Center(
          child: Container(
            margin: const EdgeInsets.only(top: 56),
            padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              '${_currentZoom.toStringAsFixed(1)}×',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Metrics Overlay ───────────────────────────────────────

  Widget _buildMetricsOverlay() {
    if (!_isStreamActive) return const SizedBox.shrink();

    final fps = _processingState.fps;
    final totalMs = _processingState.processingTimeMs;
    final convMs = _processingState.conversionTimeMs;
    final infMs = _processingState.inferenceTimeMs;
    final processed = _processingState.framesProcessed;
    final dropped = _processingState.framesDropped;
    final imgW = _processingState.processedImageWidth.toInt();
    final imgH = _processingState.processedImageHeight.toInt();
    final stability = _stabilizedResult?.stability;
    final consecutive = _stabilizedResult?.consecutiveFrames ?? 0;

    return Positioned(
      top: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.only(top: 56, right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.6),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              // FPS row
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _processingState.isProcessing
                          ? Colors.orange
                          : Colors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${fps.toStringAsFixed(1)} FPS',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),

              // Total time
              Text(
                'Total: ${totalMs.toStringAsFixed(0)} ms',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),

              // Conversion / Inference breakdown
              if (convMs > 0 || infMs > 0) ...[
                const SizedBox(height: 1),
                Text(
                  'Conv: ${convMs.toStringAsFixed(0)} | Inf: ${infMs.toStringAsFixed(0)}',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
              const SizedBox(height: 2),

              // Input resolution
              if (imgW > 0 && imgH > 0)
                Text(
                  'In: ${imgW}×$imgH',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              const SizedBox(height: 2),

              // Frame stats
              Text(
                'P:$processed D:$dropped',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),

              // Stability info
              if (stability != null) ...[
                const SizedBox(height: 2),
                Text(
                  'Stab: ${stability.name} ($consecutive)',
                  style: TextStyle(
                    color: stability == PlateStability.confirmed
                        ? Colors.green.shade300
                        : Colors.white.withOpacity(0.5),
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Bottom Result Bar ─────────────────────────────────────

  Widget _buildBottomResultBar() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.black.withOpacity(0.8),
                Colors.black.withOpacity(0.4),
                Colors.transparent,
              ],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Stabilized plate banner (animated)
              if (_stabilizedResult != null)
                ConfirmedPlateBanner(result: _stabilizedResult),

              // Searching indicator
              if (_stabilizedResult == null &&
                  _processingState.result == null &&
                  _isStreamActive)
                _buildSearchingIndicator(),

              const SizedBox(height: 12),

              // Status pill
              _buildStatusPill(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchingIndicator() {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white.withOpacity(0.6),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Searching for license plate...',
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusPill() {
    final isActive = _isStreamActive;
    final isConfirmed =
        _stabilizedResult?.stability == PlateStability.confirmed;

    final Color dotColor;
    final String statusText;

    if (isConfirmed) {
      dotColor = Colors.green;
      statusText = 'Plate confirmed ✓';
    } else if (isActive) {
      dotColor = Colors.green;
      statusText = 'Live processing active';
    } else {
      dotColor = Colors.orange;
      statusText = 'Waiting to start...';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            statusText,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ── Permission Denied Screen ──────────────────────────────

  Widget _buildPermissionDenied() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.camera_alt_outlined,
              size: 64,
              color: Colors.white54,
            ),
            const SizedBox(height: 24),
            const Text(
              'Camera Permission Required',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'Please grant camera access to use\n'
                  'real-time license plate detection.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => openAppSettings(),
              icon: const Icon(Icons.settings),
              label: const Text('Open Settings'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _navigateBack,
              child: const Text(
                'Go Back',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Error Screen ──────────────────────────────────────────

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Colors.red.shade300,
            ),
            const SizedBox(height: 24),
            Text(
              _errorMessage ?? 'An error occurred',
              style: const TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _errorMessage = null;
                  _permissionDenied = false;
                });
                _initialize();
              },
              child: const Text('Retry'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _navigateBack,
              child: const Text(
                'Go Back',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}