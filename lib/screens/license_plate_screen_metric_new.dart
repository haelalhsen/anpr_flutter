import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;

import '../config/pipeline_config.dart';
import '../services/license_plate_detector_metric_new.dart';
import '../services/model_service_manager.dart';
import '../widgets/loading_widgets.dart';

class LicensePlateScreenMetricNew extends StatefulWidget {
  final PipelineType pipelineType;
  final LicensePlateDetectorMetricNew? preloadedDetector;

  const LicensePlateScreenMetricNew({
    super.key,
    required this.pipelineType,
    this.preloadedDetector,
  });

  @override
  State<LicensePlateScreenMetricNew> createState() =>
      _LicensePlateScreenMetricNewState();
}

class _LicensePlateScreenMetricNewState
    extends State<LicensePlateScreenMetricNew>
    with SingleTickerProviderStateMixin {

  final ModelServiceManager _modelService = ModelServiceManager();
  final ImagePicker _picker = ImagePicker();

  LicensePlateDetectorMetricNew? _detector;

  bool _isInitializing = true;
  bool _isProcessing = false;
  String? _errorMessage;
  double _loadingProgress = 0.0;
  String _loadingMessage = 'Initializing...';

  File? _selectedImage;
  LicensePlateResult? _result;
  Uint8List? _croppedPlateBytes;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    // Setup fade animation for smooth transition from loading to content
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );

    // CRITICAL: Delay initialization until AFTER first frame renders
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeDetector();
    });
  }

  Future<void> _initializeDetector() async {
    // If detector was passed in (cached), use it directly
    if (widget.preloadedDetector != null) {
      setState(() {
        _detector = widget.preloadedDetector;
        _isInitializing = false;
      });
      _fadeController.forward();
      return;
    }
    // CRITICAL: Add small delay to ensure loading UI is fully rendered
    // This allows the loading overlay to appear before blocking operations
    await Future.delayed(const Duration(milliseconds: 50));

    if (!mounted) return;

    // Otherwise, load with progress updates
    try {
      setState(() {
        _loadingMessage = 'Loading detection model...';
        _loadingProgress = 0.1;
      });

      // Another small delay to ensure setState is rendered
      await Future.delayed(const Duration(milliseconds: 50));

      _detector = await _modelService.getOrLoadDetector(
        widget.pipelineType,
        delegateType: DelegateType.gpu,
        onStatusChange: (status) {
          if (mounted) {
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

      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
        _fadeController.forward();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _errorMessage = 'Failed to initialize models: $e';
        });
        _fadeController.forward();
      }
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 90,
      );

      if (pickedFile == null) return;

      setState(() {
        _selectedImage = File(pickedFile.path);
        _result = null;
        _croppedPlateBytes = null;
        _errorMessage = null;
      });

      await _processImage();
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to pick image: $e';
      });
    }
  }

  Future<void> _processImage() async {
    if (_selectedImage == null || _detector == null || !_detector!.isInitialized) {
      return;
    }

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final bytes = await _selectedImage!.readAsBytes();
      final image = img.decodeImage(bytes);

      if (image == null) {
        throw Exception('Failed to decode image');
      }

      final result = await _detector!.recognizePlate(image);

      if (result == null) {
        setState(() {
          _isProcessing = false;
          _errorMessage = 'No license plate detected in image';
        });
        return;
      }

      Uint8List? croppedBytes;
      if (result.croppedPlate != null) {
        croppedBytes = Uint8List.fromList(
          img.encodePng(result.croppedPlate!),
        );
      }

      setState(() {
        _result = result;
        _croppedPlateBytes = croppedBytes;
        _isProcessing = false;
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _errorMessage = 'Processing failed: $e';
      });
    }
  }

  void _clearResults() {
    setState(() {
      _selectedImage = null;
      _result = null;
      _croppedPlateBytes = null;
      _errorMessage = null;
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    // Don't dispose detector here - it's managed by ModelServiceManager
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = PipelineConfig.getConfig(widget.pipelineType);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isInitializing ? 'Loading...' : 'License Plate Recognition',
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (!_isInitializing && _selectedImage != null)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: _clearResults,
              tooltip: 'Clear',
            ),
        ],
      ),
      body: _buildBody(config),
      bottomNavigationBar: _isInitializing ? null : _buildBottomBar(),
    );
  }

  Widget _buildBody(PipelineConfig config) {
    // Show loading screen while initializing
    if (_isInitializing) {
      return ModelLoadingOverlay(
        pipelineName: config.name,
        progress: _loadingProgress,
        statusMessage: _loadingMessage,
      );
    }

    // Show content with fade animation
    return FadeTransition(
      opacity: _fadeAnimation,
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Error message
          if (_errorMessage != null) _buildErrorCard(),

          // Image display
          _buildImageSection(),

          const SizedBox(height: 16),

          // Processing indicator
          if (_isProcessing) _buildProcessingIndicator(),

          // Results
          if (_result != null && !_isProcessing) ...[
            _buildResultCard(),
            const SizedBox(height: 16),
            _buildCroppedPlateCard(),
            const SizedBox(height: 16),
            _buildMetricsCard(),
          ],

          // Initial state
          if (_selectedImage == null && !_isProcessing) _buildPlaceholder(),
        ],
      ),
    );
  }

  Widget _buildErrorCard() {
    return Card(
      color: Colors.red.shade50,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red.shade700),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _errorMessage!,
                style: TextStyle(color: Colors.red.shade700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageSection() {
    if (_selectedImage == null) return const SizedBox.shrink();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.grey.shade100,
            child: const Row(
              children: [
                Icon(Icons.image, size: 20),
                SizedBox(width: 8),
                Text(
                  'Selected Image',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          Stack(
            children: [
              Image.file(
                _selectedImage!,
                fit: BoxFit.contain,
                width: double.infinity,
              ),
              if (_result?.plateBox != null)
                Positioned.fill(
                  child: CustomPaint(
                    painter: BoundingBoxPainter(
                      box: _result!.plateBox!,
                      imageFile: _selectedImage!,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProcessingIndicator() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Processing image...',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard() {
    return Card(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle, color: Colors.green),
                SizedBox(width: 8),
                Text(
                  'Recognition Result',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 12,
              ),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.shade300, width: 2),
              ),
              child: Text(
                _result!.fullPlate,
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  letterSpacing: 4,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildLabelChip('Code', _result!.code),
                const SizedBox(width: 16),
                _buildLabelChip('Number', _result!.number),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLabelChip(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.grey.shade600,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.grey.shade200,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            value.isEmpty ? '-' : value,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCroppedPlateCard() {
    if (_croppedPlateBytes == null) return const SizedBox.shrink();

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.grey.shade100,
            child: const Row(
              children: [
                Icon(Icons.crop, size: 20),
                SizedBox(width: 8),
                Text(
                  'Detected Plate Region',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 100),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Image.memory(
                  _croppedPlateBytes!,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsCard() {
    final metrics = _result!.metrics;
    metrics.printMetrics();

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.grey.shade100,
            child: const Row(
              children: [
                Icon(Icons.speed, size: 20),
                SizedBox(width: 8),
                Text(
                  'Performance Metrics',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _buildMetricRow('Detection', metrics.detectionMs),
                _buildMetricRow('Cropping', metrics.croppingMs),
                _buildMetricRow('OCR', metrics.ocrMs),
                _buildMetricRow('Logic', metrics.logicMs),
                const Divider(),
                _buildMetricRow(
                  'Total E2E',
                  metrics.totalMs,
                  isTotal: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricRow(String label, double valueMs, {bool isTotal = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
              fontSize: isTotal ? 16 : 14,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: isTotal ? Colors.blue.shade100 : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${valueMs.toStringAsFixed(2)} ms',
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
                color: isTotal ? Colors.blue.shade800 : Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(
          children: [
            Icon(
              Icons.directions_car,
              size: 64,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 16),
            Text(
              'Select an image to recognize license plate',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Use the buttons below to pick from gallery\nor capture with camera',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade500,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isProcessing
                    ? null
                    : () => _pickImage(ImageSource.gallery),
                icon: const Icon(Icons.photo_library),
                label: const Text('Gallery'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isProcessing
                    ? null
                    : () => _pickImage(ImageSource.camera),
                icon: const Icon(Icons.camera_alt),
                label: const Text('Camera'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Custom painter for drawing bounding box overlay
class BoundingBoxPainter extends CustomPainter {
  final DetectionBox box;
  final File imageFile;

  BoundingBoxPainter({required this.box, required this.imageFile});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    // Simplified - in production scale coordinates properly
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}