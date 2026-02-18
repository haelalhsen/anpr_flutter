/// Pipeline types available in the app
enum PipelineType {
  fullPipelineFloat32_640,
  // Add more pipelines here as needed:
  // fullPipelineFloat16_640,
  // fastPipelineInt8_320,
}

/// Configuration for each pipeline
class PipelineConfig {
  final String name;
  final String detModelPath;
  final String ocrModelPath;
  final String description;

  const PipelineConfig({
    required this.name,
    required this.detModelPath,
    required this.ocrModelPath,
    required this.description,
  });

  /// Get configuration for a specific pipeline type
  static PipelineConfig getConfig(PipelineType type) {
    switch (type) {
      case PipelineType.fullPipelineFloat32_640:
        return const PipelineConfig(
          name: 'Full Pipeline - Float32 - 640',
          detModelPath: 'assets/models/detection_model_float32.tflite',
          ocrModelPath: 'assets/models/ocr_model_float32.tflite',
          description: 'High accuracy detection with float32 precision',
        );
    // Add more cases for other pipelines:
    // case PipelineType.fullPipelineFloat16_640:
    //   return const PipelineConfig(
    //     name: 'Full Pipeline - Float16 - 640',
    //     detModelPath: 'assets/models/best_float16.tflite',
    //     ocrModelPath: 'assets/models/ocr_model_float16.tflite',
    //     description: 'Balanced accuracy and speed with float16',
    //   );
    }
  }
}