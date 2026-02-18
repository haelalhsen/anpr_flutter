import 'package:flutter/material.dart';
import 'config/pipeline_config.dart';
import 'services/model_service_manager.dart';
import 'services/license_plate_detector_metric_new.dart';
import 'screens/license_plate_screen_metric_new.dart';
import 'screens/real_time_lpr_screen.dart';
import 'screens/scan_lpn_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void dispose() {
    ModelServiceManager().disposeAll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ANPR Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const ChoosePipeline(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ChoosePipeline extends StatelessWidget {
  const ChoosePipeline({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose Pipeline Type'),
        centerTitle: true,
        elevation: 2,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Section: Single Image ──────────────────────
              Text(
                'Single Image',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade600,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),

              _PipelineButton(
                pipelineType: PipelineType.fullPipelineFloat32_640,
                icon: Icons.high_quality,
                color: Colors.green,
                mode: _LaunchMode.singleImage,
              ),

              const SizedBox(height: 24),

              // ── Section: Real-Time ─────────────────────────
              Text(
                'Real-Time Camera',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade600,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),

              _PipelineButton(
                pipelineType: PipelineType.fullPipelineFloat32_640,
                icon: Icons.videocam,
                color: Colors.blue,
                mode: _LaunchMode.realTime,
              ),

              const SizedBox(height: 24),

              // ── Section: Scan LPN ──────────────────────────
              Text(
                'Scan License Plate',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade600,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),

              _PipelineButton(
                pipelineType: PipelineType.fullPipelineFloat32_640,
                icon: Icons.document_scanner,
                color: Colors.orange,
                mode: _LaunchMode.scanLpn,
              ),

              const SizedBox(height: 32),

              // ── Cache status ───────────────────────────────
              _CacheStatusWidget(),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  Launch Mode
// ══════════════════════════════════════════════════════════════

enum _LaunchMode { singleImage, realTime, scanLpn }

// ══════════════════════════════════════════════════════════════
//  Pipeline Button
// ══════════════════════════════════════════════════════════════

class _PipelineButton extends StatelessWidget {
  final PipelineType pipelineType;
  final IconData icon;
  final Color color;
  final _LaunchMode mode;

  const _PipelineButton({
    required this.pipelineType,
    required this.icon,
    required this.color,
    required this.mode,
  });

  @override
  Widget build(BuildContext context) {
    final config = PipelineConfig.getConfig(pipelineType);
    final modelService = ModelServiceManager();
    final isCached = modelService.isDetectorCached(pipelineType);

    final String subtitle;
    final String title;

    switch (mode) {
      case _LaunchMode.realTime:
        title = '${config.name} (Real-Time)';
        subtitle = '${config.description} • Live camera';
        break;
      case _LaunchMode.scanLpn:
        title = 'Scan LPN';
        subtitle = 'Auto-detect & recognize a single plate';
        break;
      case _LaunchMode.singleImage:
        title = config.name;
        subtitle = config.description;
        break;
    }

    return Card(
      elevation: 2,
      child: InkWell(
        onTap: () => _navigate(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Icon
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 32),
              ),

              const SizedBox(width: 16),

              // Text
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        if (isCached)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.green.shade100,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.check_circle,
                                  size: 14,
                                  color: Colors.green.shade700,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Ready',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.green.shade700,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              Icon(
                Icons.arrow_forward_ios,
                color: Colors.grey.shade400,
                size: 16,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _navigate(BuildContext context) {
    final modelService = ModelServiceManager();
    final cachedDetector = modelService.getCachedDetector(pipelineType);

    final Widget screen;

    switch (mode) {
      case _LaunchMode.singleImage:
        screen = LicensePlateScreenMetricNew(
          pipelineType: pipelineType,
          preloadedDetector: cachedDetector,
        );
        break;
      case _LaunchMode.realTime:
        screen = RealTimeLprScreen(
          pipelineType: pipelineType,
          preloadedDetector: cachedDetector,
        );
        break;
      case _LaunchMode.scanLpn:
        screen = ScanLpnScreen(
          pipelineType: pipelineType,
          preloadedDetector: cachedDetector,
        );
        break;
    }

    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => screen),
    );
  }
}

// ══════════════════════════════════════════════════════════════
//  Cache Status (Debug)
// ══════════════════════════════════════════════════════════════

class _CacheStatusWidget extends StatefulWidget {
  @override
  State<_CacheStatusWidget> createState() => _CacheStatusWidgetState();
}

class _CacheStatusWidgetState extends State<_CacheStatusWidget> {
  @override
  Widget build(BuildContext context) {
    final debugInfo = ModelServiceManager().getDebugInfo();
    final cachedPipelines = debugInfo['cachedPipelines'] as List;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.memory, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Text(
            'Cached: ${cachedPipelines.isEmpty ? "None" : cachedPipelines.length} pipeline(s)',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          if (cachedPipelines.isNotEmpty) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () {
                ModelServiceManager().disposeAll();
                setState(() {});
              },
              child: Text(
                'Clear',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.blue.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}