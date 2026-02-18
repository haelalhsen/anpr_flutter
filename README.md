# ANPR Scanner — Flutter R&D Application

> **Purpose:** This is a **research and development reference application** for Automatic Number Plate Recognition (ANPR) on mobile devices using on-device TFLite models. It is not a production app. Its features, patterns, and architecture are intended to be studied, benchmarked, and selectively integrated into production apps.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Tech Stack & Dependencies](#2-tech-stack--dependencies)
3. [AI Models](#3-ai-models)
4. [Project Structure](#4-project-structure)
5. [Architecture Overview](#5-architecture-overview)
6. [Feature 1 — Single Image LPR](#6-feature-1--single-image-lpr)
7. [Feature 2 — Real-Time Camera LPR](#7-feature-2--real-time-camera-lpr)
8. [Feature 3 — Scan LPN](#8-feature-3--scan-lpn)
9. [Core Services](#9-core-services)
10. [Utility Layer](#10-utility-layer)
11. [Widget Library](#11-widget-library)
12. [Configuration System](#12-configuration-system)
13. [Performance Characteristics](#13-performance-characteristics)
14. [Data Flow Diagrams](#14-data-flow-diagrams)
15. [Key Design Decisions & R&D Notes](#15-key-design-decisions--rd-notes)
16. [Integration Guide for Production Apps](#16-integration-guide-for-production-apps)
17. [Known Limitations & Future Work](#17-known-limitations--future-work)
18. [Revision History](#18-revision-history)

---

## 1. Project Overview

The ANPR Scanner app implements a full **License Plate Recognition (LPR)** pipeline on-device using two TFLite neural networks:

- A **YOLOv8 detection model** that locates the plate region in an image.
- An **OCR model** that reads the characters from the cropped plate region.

The app exposes this pipeline in three distinct usage modes, each designed to explore a different integration pattern:

| Mode | Use Case Explored |
|---|---|
| **Single Image** | Offline / gallery-based processing, max accuracy |
| **Real-Time Camera** | Continuous live processing, stabilization, history |
| **Scan LPN** | One-shot auto-capture: detect → freeze → recognize |

All three modes share the same underlying model pipeline and service infrastructure, demonstrating how a single AI backend can power multiple UX paradigms.

---

## 2. Tech Stack & Dependencies

### Flutter / Dart
- Flutter SDK (null-safe Dart)
- `camera` — camera preview and raw image stream access
- `permission_handler` — runtime camera permission handling
- `image_picker` — gallery and camera capture for single image mode
- `image` (pub: `image`) — in-memory image manipulation (resize, crop, encode/decode)
- `tflite_flutter` — TFLite interpreter with GPU/NNAPI delegate support

### Platform Support
| Platform | Status |
|---|---|
| Android | ✅ Primary target |
| iOS | ✅ Supported (BGRA8888 camera format path) |

### Minimum Requirements
- Android: API 21+, GPU delegate requires OpenGL ES 3.1+
- iOS: iOS 12+, Metal GPU delegate

---

## 3. AI Models

Both models live in `assets/models/` and are loaded at runtime via `tflite_flutter`.

### Detection Model — `detection_model_float32.tflite`

| Property | Value |
|---|---|
| Architecture | YOLOv8 |
| Input | `[1, 640, 640, 3]` — RGB float32, normalized 0–1 |
| Output | `[1, 5, 8400]` — center_x, center_y, width, height, confidence |
| Precision | Float32 |
| Task | Locate the license plate bounding box in the full image |
| Confidence threshold | 0.40 (static image), 0.50 (real-time), 0.65 (scan/capture) |

**Output format note:** The model outputs in YOLOv8 transposed format — `[batch, attributes, detections]` — where attributes are `[cx, cy, w, h, class_conf...]`. Values may be normalized (≤ 2.0) or in pixel space; the parser handles both cases.

### OCR Model — `ocr_model_float32.tflite`

| Property | Value |
|---|---|
| Input | `[1, 160, 160, 3]` — RGB float32, normalized 0–1 |
| Output | `[1, 40, N]` — YOLOv8-style character detections |
| Precision | Float32 |
| Classes | 36 — digits `0–9` and uppercase letters `A–Z` |
| Task | Detect and classify individual characters on the cropped plate |
| Confidence threshold | 0.15 (static), 0.20 (real-time) |

**Character map:**

```
0–9  → '0'–'9'   (class IDs 0–9)
A–Z  → 'A'–'Z'   (class IDs 10–35)
```

### Letterbox Pre-processing

Both models require letterboxed input — the image is scaled to fit within the target resolution while preserving aspect ratio, with gray padding (`114/255 ≈ 0.447`) filling the remaining space. The padding offsets (`padW`, `padH`) and scale ratio are tracked and used to map output coordinates back to the original image space.

### GPU Delegate

The app uses `GpuDelegateV2` on iOS and tries NNAPI first on Android (falling back to GPU). The delegate is configured with `isPrecisionLossAllowed: true` for additional speed. Both interpreters (detection + OCR) receive their own delegate instance.

---

## 4. Project Structure

```
lib/
├── main.dart                              Entry point, home screen, navigation
│
├── config/
│   ├── pipeline_config.dart               Pipeline type enum + model path config
│   └── realtime_config.dart               All real-time tuning constants
│
├── services/
│   ├── license_plate_detector_metric_new.dart   Core LPR pipeline (detection + OCR)
│   ├── model_service_manager.dart               Singleton model cache + loading
│   ├── camera_frame_processor.dart              Real-time frame gating + pipeline runner
│   ├── plate_result_stabilizer.dart             Cross-frame result stabilization
│   └── detection_only_processor.dart            Detection-only frame processor (Scan LPN)
│
├── screens/
│   ├── license_plate_screen_metric_new.dart     Single Image mode screen
│   ├── real_time_lpr_screen.dart                Real-Time mode screen
│   └── scan_lpn_screen.dart                     Scan LPN mode screen
│
├── utils/
│   ├── image_conversion.dart                    Basic YUV420/BGRA8888 converter
│   └── image_conversion_optimized.dart          Optimized converter with LUTs + isolate
│
└── widgets/
    ├── loading_widgets.dart                     ModelLoadingOverlay, shimmer, skeleton
    ├── detection_overlay.dart                   Animated bounding box overlay
    ├── confirmed_plate_banner.dart              Slide-up confirmation banner
    ├── plate_history_sheet.dart                 Bottom sheet detection history log
    └── scan_result_overlay.dart                 Frozen frame view + result card (Scan LPN)

assets/
└── models/
    ├── detection_model_float32.tflite           Detection model
    └── ocr_model_float32.tflite                 OCR model
```

---

## 5. Architecture Overview

### Layered Architecture

```
┌─────────────────────────────────────────────────┐
│                    UI Layer                      │
│   Screens + Widgets (stateful, phase-driven)     │
└───────────────────┬─────────────────────────────┘
                    │
┌───────────────────▼─────────────────────────────┐
│               Orchestration Layer                │
│   CameraFrameProcessor / DetectionOnlyProcessor  │
│   PlateResultStabilizer                          │
└───────────────────┬─────────────────────────────┘
                    │
┌───────────────────▼─────────────────────────────┐
│               Pipeline Layer                     │
│   LicensePlateDetectorMetricNew                  │
│   (detection → crop → OCR → logic)               │
└───────────────────┬─────────────────────────────┘
                    │
┌───────────────────▼─────────────────────────────┐
│               Infrastructure Layer               │
│   ModelServiceManager  (singleton cache)         │
│   CameraImageConverterOptimized  (YUV→RGB)       │
│   TFLite Interpreters  (GPU delegate)            │
└─────────────────────────────────────────────────┘
```

### Singleton Model Cache

`ModelServiceManager` is a Dart singleton that caches loaded `LicensePlateDetectorMetricNew` instances keyed by `PipelineType`. This means:

- First launch: models load from assets (~1–3 seconds depending on device).
- Subsequent navigation to any mode: detector is retrieved from cache instantly.
- The "Ready" badge on the home screen reflects cache state.
- `disposeAll()` is called in `MyApp.dispose()` to clean up on app exit.

### Isolate Architecture (Real-Time)

```
Main Isolate                      Background Isolate
─────────────────                 ──────────────────
camera.startImageStream()
  → CameraFrameProcessor
      ↓ extract bytes (fast)
      ↓ compute(_convertInIsolate) ──→ YUV→RGB conversion
      ↓                            ←── img.Image
      ↓ recognizePlate()  ← must stay on main (TFLite native pointers)
      ↓ setState()
```

Image conversion is offloaded to a `compute()` isolate when `RealtimeConfig.useIsolateConversion = true`. TFLite inference **must** remain on the main isolate because the `Interpreter` holds native memory pointers that are not transferable.

---

## 6. Feature 1 — Single Image LPR

**Screen:** `screens/license_plate_screen_metric_new.dart`

### User Flow

```
Open screen → [Loading overlay: models init]
           → Pick image (gallery or camera)
           → Processing spinner
           → Result: plate text + cropped region + metrics
```

### Key Behaviors

- **Image source:** `ImagePicker` with `maxWidth: 1920`, `maxHeight: 1080`, `quality: 90`. Works from gallery or camera capture.
- **Processing:** `img.decodeImage()` → `detector.recognizePlate(image)` → display result.
- **Bounding box overlay:** `BoundingBoxPainter` draws on top of the selected image using `CustomPainter`. *(Note: coordinate scaling is simplified in the current implementation — production integration should use `PreviewCoordinateMapper` logic.)*
- **Results displayed:**
    - Full plate string (e.g. `ABC-1234`)
    - Separated `code` and `number` fields
    - Cropped plate thumbnail (PNG-encoded from `result.croppedPlate`)
    - Metrics card: detection ms, cropping ms, OCR ms, logic ms, total E2E ms
- **Model loading:** Uses `ModelServiceManager.getOrLoadDetector()` with a progress callback. A `FadeTransition` is used to smoothly reveal content after loading.
- **Preloaded detector:** If the detector was already loaded by a previous screen visit, it is passed in via `preloadedDetector` constructor parameter, skipping the loading state entirely.

### Performance

On a mid-range device with GPU delegate, typical E2E times:
- Detection: ~150–250 ms
- OCR: ~100–200 ms
- Total: ~300–500 ms per image

---

## 7. Feature 2 — Real-Time Camera LPR

**Screen:** `screens/real_time_lpr_screen.dart`

### User Flow

```
Open screen → [Camera + model init in parallel]
           → Live camera preview with detection overlay
           → Detected plates shown in bounding box + label
           → After N consecutive identical frames → CONFIRMED
           → Haptic feedback + banner + history log
```

### Phase Management

The screen is always in one of these implicit states:
- **Initializing:** camera + model loading in parallel (`Future.wait`)
- **Streaming:** `startImageStream` active, `CameraFrameProcessor` running
- **Inactive:** app backgrounded, stream paused

### CameraFrameProcessor

Sits between the raw camera stream and the LPR pipeline. Responsibilities:

1. **Frame gating:** Drops frames while a previous frame is still processing. Enforces `minFrameIntervalMs` to control thermal load.
2. **Image conversion:** Calls `CameraImageConverterOptimized.convertAsync()` (or `convertSync()`). Conversion runs in a `compute()` isolate when enabled.
3. **Inference:** Calls `detector.recognizePlate(convertedImage)` on the main isolate.
4. **Result retention:** Keeps the last valid result visible for `resultRetentionMs` after detection is lost, preventing flickering.
5. **FPS tracking:** Maintains a sliding window of the last 10 frame completion timestamps.
6. **State broadcasting:** Emits `ProcessingState` on every frame (processed or dropped) via `onStateUpdate` callback.

```dart
class ProcessingState {
  final LicensePlateResult? result;
  final double processingTimeMs;
  final double conversionTimeMs;
  final double inferenceTimeMs;
  final double fps;
  final bool isProcessing;
  final int framesProcessed;
  final int framesDropped;
  final double processedImageWidth;   // For coordinate mapping
  final double processedImageHeight;
}
```

### PlateResultStabilizer

Receives `LicensePlateResult?` on every frame and tracks plate identity across frames:

```
Frame N:   ABC-1234  → PlateStability.detected    (consecutiveFrames: 1)
Frame N+1: ABC-1234  → PlateStability.confirming  (consecutiveFrames: 2)
Frame N+2: ABC-1234  → PlateStability.confirmed   (consecutiveFrames: 3) → haptic!
Frame N+3: ABC-1235  → PlateStability.detected    (new plate, reset)
```

**Fuzzy matching:** Plates differing by 1 character are treated as the same plate (handles OCR jitter between frames). Plates differing by more than 1 character or different lengths (>1) trigger a reset.

**History:** Confirmed plates are appended to an in-memory list (max 50 entries). Duplicate detections within 5 seconds are suppressed. The history is shown in `PlateHistorySheet`.

**Haptics:** `HapticFeedback.mediumImpact()` fires on the first confirmation of each new plate.

### Detection Overlay

`DetectionOverlay` renders on top of the camera preview using `CustomPaint`. It:
- Maps detection coordinates from processed image space to display space via `PreviewCoordinateMapper`, correctly handling `BoxFit.cover` letterboxing/pillarboxing.
- Smoothly interpolates (`lerp`) the bounding box between frames at ~60fps using an `AnimationController`.
- Fades out when detection is lost (after `staleFrameThreshold` frames).
- Draws corner brackets, a semi-transparent fill, confidence badge, and plate text label.

### Camera Controls

| Control | Implementation |
|---|---|
| Pinch to zoom | `GestureDetector.onScaleUpdate` → `controller.setZoomLevel()` |
| Tap to focus | `GestureDetector.onTapDown` → `controller.setFocusPoint()` + `setExposurePoint()` |
| Torch | `controller.setFlashMode(FlashMode.torch / FlashMode.off)` |

### Lifecycle Safety

`didChangeAppLifecycleState` handles app backgrounding:
- `inactive` → stop stream + dispose camera controller
- `resumed` → re-initialize camera + restart processing

`_isNavigatingBack` and `_isDisposed` flags prevent race conditions during navigation. `PopScope(canPop: false)` intercepts the back gesture to ensure clean teardown before `Navigator.pop()`.

---

## 8. Feature 3 — Scan LPN

**Screen:** `screens/scan_lpn_screen.dart`  
**Processor:** `services/detection_only_processor.dart`  
**Widgets:** `widgets/scan_result_overlay.dart`

### Concept

Unlike Real-Time mode (which processes continuously), Scan LPN is a **one-shot flow**: detect a plate confidently → freeze the frame → run high-accuracy OCR on the frozen image → show the result. This is ideal for integration into forms or workflows where you need one confirmed plate reading per session.

### Phase State Machine

```
loading ──→ scanning ──→ capturing ──→ recognizing ──→ result
                ↑                                        │
                └──────────── (scan again) ──────────────┘
```

```dart
enum ScanPhase {
  loading,      // Camera + model initializing
  scanning,     // Live preview, detection-only loop
  capturing,    // Plate detected, freezing frame + flash
  recognizing,  // OCR running on frozen frame
  result,       // Displaying result card
  error,
}
```

### DetectionOnlyProcessor

The processor runs every live frame through the full detection model but discards OCR output — only `result.plateBox` is read. Before firing the capture callback, every frame must pass through a **multi-gate quality pipeline** implemented by the internal `_StabilityTracker`. A single confident detection is not enough to trigger capture; the plate must be stable across multiple consecutive frames.

```dart
class CapturedFrame {
  final img.Image fullImage;   // Full converted frame (for OCR)
  final DetectionBox plateBox; // Detection box in fullImage coordinates
}
```

**Why store the converted image?** The frame used for detection is the same frame handed to OCR. This avoids a second YUV→RGB conversion and guarantees the OCR receives exactly the image that passed all quality gates.

### Quality Gate Pipeline (`CaptureQualityConfig`)

Every processed frame must pass all five gates. Failure on any gate resets the consecutive-frame counter:

| Gate | Parameter | Default | Purpose |
|---|---|---|---|
| 1 — Detection present | — | — | No box → reset |
| 2 — Minimum confidence | `minConfidence` | `0.55` | Weak detections ignored |
| 3 — Minimum plate size | `minPlateAreaFraction` | `0.005` | Rejects tiny far-away plates |
| 4 — Centre movement | `maxCentreMoveFraction` | `0.08` | Camera panning / hand shake |
| 5 — Area change | `maxAreaChangeFraction` | `0.06` | Zoom-in / zoom-out drift |
| 6 — Consecutive count | `requiredStableFrames` | `3` | Must sustain gates 1–5 for N frames |

When all gates pass for `requiredStableFrames` consecutive frames, `onReadyToCapture` fires with the **highest-confidence frame from the stable run** — not just the triggering frame. This is the key quality guarantee: the best image from the stable window, not a random one.

The `_StabilityTracker` maintains two reset modes:
- **Soft reset** (no detection this frame) — clears run counters and position baseline entirely
- **Movement reset** (box moved) — clears run counters but updates the position baseline so the next frame has a valid comparison point

**Callbacks:**

```dart
// Fires on every processed frame — drives live overlay + stability progress bar
onFrameResult: (box, imgW, imgH, stableCount, requiredCount) { ... }

// Fires exactly once per scan cycle when all gates pass
onReadyToCapture: (CapturedFrame frame) { ... }
```

### Two-Stage Pipeline

```
Stage 1 (scanning phase):
  Live frames → DetectionOnlyProcessor
    → YUV→RGB conversion (isolate)
    → recognizePlate(frame) — reads plateBox only, discards OCR
    → _StabilityTracker.feed() — runs all 5 quality gates
    → if N consecutive frames pass → onReadyToCapture(bestFrame)

Stage 2 (recognizing phase):
  CapturedFrame.fullImage → detector.recognizePlate(fullImage)
    → full detection + OCR on frozen frame
    → LicensePlateResult { fullPlate, code, number, croppedPlate, metrics }
```

### Stability Progress UI

The screen surfaces `stableCount` / `requiredCount` to the user via:
- A **segmented bar** (N segments, one per required frame, filling green as stability builds)
- A **determinate `CircularProgressIndicator`** during the locking state
- Guide box border that **interpolates white → green** as `stableCount / requiredCount` increases
- Three animated hint states: `searching` → `detected` → `locking`

### FrozenFrameView

Displays the captured `img.Image` as a static image with an animated bounding box overlay:
- PNG encoding runs via `compute()` to avoid blocking the UI during the `recognizing` phase.
- `_FrozenBoxPainter` uses `BoxFit.contain` coordinate math (pillarbox/letterbox) — the inverse of real-time mode's `BoxFit.cover` math in `PreviewCoordinateMapper`.
- The box pulses (opacity animation) during the `recognizing` phase to indicate activity.

### ScanResultCard

The result display panel:
- Slides up from the bottom with a `SlideTransition` + `FadeTransition`.
- Shows full plate text (large monospace), code/number chips, confidence, cropped plate thumbnail, and full metrics breakdown.
- **"Scan Again"** resets to `scanning` phase and restarts the image stream.
- **"Done"** calls `_navigateBack()`.

---

## 9. Core Services

### `LicensePlateDetectorMetricNew`

The central pipeline class. All three modes ultimately call `recognizePlate(img.Image)`.

**Pipeline steps:**

```
recognizePlate(image)
  │
  ├─ 1. _runDetectionOptimized(image)
  │       → letterbox image to 640×640
  │       → run detection interpreter
  │       → parse YOLOv8 output
  │       → NMS (IoU threshold 0.45)
  │       → return List<DetectionBox>
  │
  ├─ 2. _getBestDetection(detections)
  │       → highest confidence box
  │
  ├─ 3. _cropPlate(image, bestBox)
  │       → add 5% padding around box
  │       → img.copyCrop()
  │
  ├─ 4. _runOCROptimized(croppedPlate)
  │       → letterbox to 160×160
  │       → run OCR interpreter
  │       → parse character detections
  │       → NMS
  │       → return List<CharDetection> (x, y, char, confidence)
  │
  └─ 5. _processCharacters(chars)
          → sort by x position (left → right)
          → detect letter/number split
          → return (code, number)
```

**Character processing logic:**
- If any uppercase letters present: `_splitLettersNumbers()` — letters → code, digits → number.
- If all digits: `_splitByGap()` — finds the largest horizontal gap between characters; if gap > 1.8× average gap, split there.

**Buffer reuse:** `_detInputBuffer`, `_ocrInputBuffer`, `_detOutputBuffer`, `_ocrOutputBuffer` are pre-allocated once in `_preallocateBuffers()` and reused on every inference call, avoiding GC pressure in real-time mode.

**NMS (Non-Maximum Suppression):** Standard greedy NMS — sort by confidence descending, greedily keep boxes with IoU < 0.45 against all already-kept boxes.

### `ModelServiceManager`

Dart singleton (`factory` constructor pattern). Provides:

```dart
// Load or return cached detector
Future<LicensePlateDetectorMetricNew> getOrLoadDetector(
  PipelineType type, {
  DelegateType delegateType,
  void Function(LoadingStatus)? onStatusChange,
})

// Synchronous cache check (for UI badge)
bool isDetectorCached(PipelineType type)
LicensePlateDetectorMetricNew? getCachedDetector(PipelineType type)

// Cleanup
void disposeDetector(PipelineType type)
void disposeAll()
```

Loading status is broadcast via `StreamController<LoadingStatus>` per pipeline type. If a second caller requests a pipeline that is mid-load, it subscribes to the stream and waits rather than starting a duplicate load.

### `CameraFrameProcessor`

See [Feature 2](#7-feature-2--real-time-camera-lpr) for full details.

### `PlateResultStabilizer`

See [Feature 2](#7-feature-2--real-time-camera-lpr) for full details.

### `DetectionOnlyProcessor`

See [Feature 3](#8-feature-3--scan-lpn) for full details.

---

## 10. Utility Layer

### `CameraImageConverterOptimized`

The primary image conversion utility used in real-time and scan modes.

**Why custom conversion?** Flutter's `camera` package provides raw `CameraImage` frames in platform-native formats — YUV420 on Android, BGRA8888 on iOS. The `image` package cannot decode these directly, so manual pixel-by-pixel conversion is required.

**Key components:**

```
_CameraFrameData          Serializable DTO — raw bytes extracted from CameraImage
                          on the main isolate before being sent to compute()

_YuvLookupTables          Pre-computed 256-entry Int16List tables for BT.601 YUV→RGB:
                            R = Y + vToR[V]
                            G = Y + uToG[U] + vToG[V]
                            B = Y + uToB[U]
                          Eliminates per-pixel floating point math.
                          ~256KB memory cost, significant CPU reduction.

convertAsync()            Extracts bytes on main isolate → compute(_convertInIsolate)
convertSync()             Extracts bytes + converts on main isolate
warmUp()                  Call once at startup to pre-initialize lookup tables
```

**Downsample factor:** `downsampleFactor = 1` means full resolution. Factor 2 = half resolution in each dimension. Since the detection model input is 640×640, feeding ~640×480 loses no accuracy while halving conversion cost.

**Maximum dimension cap:** After conversion and before rotation, `_enforceMaxDimension()` ensures the image never exceeds `RealtimeConfig.maxProcessingDimension` (720px) regardless of camera resolution. Uses `img.Interpolation.nearest` for speed.

**Rotation:** `img.copyRotate(result, angle: sensorOrientation)` corrects for the camera sensor orientation. Most back cameras report `sensorOrientation = 90`.

### `CameraImageConverter`

A simpler reference implementation without lookup tables or isolate support. Useful for understanding the base conversion logic. Not used in production paths — `CameraImageConverterOptimized` is used everywhere.

---

## 11. Widget Library

### `ModelLoadingOverlay`

Full-screen loading state shown while TFLite models initialize. Features an animated memory icon, pipeline name, status message, and a `LinearProgressIndicator`. The progress value is driven by `LoadingStatus.progress` callbacks from `ModelServiceManager`.

### `DetectionOverlay` + `PreviewCoordinateMapper`

`PreviewCoordinateMapper` converts detection box coordinates from processed-image space to display-widget space, accounting for `BoxFit.cover` scaling:

```
if (displayAspect > imageAspect):
  # display is wider → image fills height, crops width
  scaledH = displayHeight
  scaledW = displayHeight * imageAspect
  offsetX = (displayWidth - scaledW) / 2   ← letterbox padding
  offsetY = 0

else:
  # display is taller → image fills width, crops height
  scaledW = displayWidth
  scaledH = displayWidth / imageAspect
  offsetX = 0
  offsetY = (displayHeight - scaledH) / 2  ← pillarbox padding
```

`DetectionOverlay` maintains a `_TrackedBox` that lerps toward the target rect each animation tick (`_lerpSpeed = 0.35`), producing smooth box movement between frames.

### `ConfirmedPlateBanner`

Animated slide-up + fade + scale banner showing the stabilized plate result. Displays differently based on `PlateStability`:
- `detected` → blue-grey background, eye icon, frame counter
- `confirmed` → green background, checkmark icon, "CONFIRMED" label

### `PlateHistorySheet`

`DraggableScrollableSheet` (30%–85% height) showing confirmed plates in reverse chronological order. Each tile is tappable to copy the plate text to clipboard. Confidence color coding: green ≥80%, orange ≥60%, red <60%.

### `ScanResultCard` (Scan LPN)

Slide-up result panel showing: plate text, code/number chips, confidence, cropped plate thumbnail, performance metrics table, and action buttons.

### `FrozenFrameView` (Scan LPN)

Static display of the captured frame with an animated bounding box overlay. Handles `BoxFit.contain` coordinate mapping (opposite of real-time's `BoxFit.cover`).

### `CaptureFlashOverlay` (Scan LPN)

300ms white flash fade-out mimicking a camera shutter. Fires `onComplete` when animation ends to chain into the OCR phase.

### `RecognizingOverlay` (Scan LPN)

Semi-transparent overlay with a spinner shown during OCR processing on the frozen frame.

---

## 12. Configuration System

### `PipelineConfig` / `PipelineType`

Defines which model files are used for each pipeline variant. Currently one variant exists:

```dart
enum PipelineType {
  fullPipelineFloat32_640,
  // future: fullPipelineFloat16_640, fastPipelineInt8_320
}
```

Adding a new model variant requires:
1. Adding an enum case to `PipelineType`
2. Adding a `PipelineConfig` entry with model asset paths
3. Adding the `.tflite` files to `assets/models/`
4. Registering the assets in `pubspec.yaml`

### `RealtimeConfig`

All real-time tuning parameters in one place. Key values:

| Parameter | Default | Effect |
|---|---|---|
| `downsampleFactor` | `1` | Frame resolution divisor during YUV conversion |
| `useIsolateConversion` | `true` | Offload YUV→RGB to background isolate |
| `minFrameIntervalMs` | `100` | Max ~10 FPS throughput cap |
| `confirmationFrameCount` | `3` | Consecutive identical frames to confirm a plate |
| `resultRetentionMs` | `800` | How long to hold last result after detection loss |
| `staleFrameThreshold` | `3` | Frames without detection before clearing overlay |
| `maxProcessingDimension` | `720` | Safety cap on converted image size |
| `useLookupTables` | `true` | Pre-computed YUV tables vs float math |

**Tuning for production:** Increase `minFrameIntervalMs` (e.g. 200–500) to reduce battery and thermal load. Increase `confirmationFrameCount` (e.g. 5) for higher result confidence at the cost of latency. For Scan LPN quality gates, see `CaptureQualityConfig` in `detection_only_processor.dart`.

---

## 13. Performance Characteristics

Benchmarks on a mid-range Android device (Snapdragon 7-series, GPU delegate):

| Metric | Single Image | Real-Time | Scan LPN |
|---|---|---|---|
| E2E pipeline | ~350–500 ms | ~350–500 ms | ~350–500 ms (OCR pass) |
| Effective FPS | N/A | ~2–3 FPS | N/A |
| YUV→RGB conversion | N/A | ~50–100 ms (main), ~15–30 ms (isolate) | ~50–100 ms |
| Detection inference | ~150–250 ms | ~150–250 ms | ~150–250 ms |
| OCR inference | ~100–200 ms | ~100–200 ms | ~100–200 ms |
| Model load time | ~1–3 s (cold) | ~1–3 s (cold) | ~1–3 s (cold) |
| Model load (cached) | <1 ms | <1 ms | <1 ms |

**Bottlenecks (ranked):**
1. TFLite inference (detection + OCR) — GPU delegate recommended, not optional
2. YUV→RGB pixel conversion — lookup tables + isolate offloading essential
3. `img.copyResize()` for letterboxing — uses `Interpolation.nearest` (fastest)
4. PNG encoding of results — offloaded to `compute()` in Scan LPN

---

## 14. Data Flow Diagrams

### Single Image Mode

```
User picks image
      │
      ▼
img.decodeImage(bytes)
      │
      ▼
LicensePlateDetectorMetricNew.recognizePlate(image)
      │
      ├─→ _letterboxIntoBuffer(image, 640×640) → Float32List
      ├─→ detInterpreter.run() → [1, 5, 8400] output
      ├─→ _parseDetectionsOptimized() → List<DetectionBox>
      ├─→ NMS → best DetectionBox
      ├─→ _cropPlate(image, box) → img.Image (plate region)
      ├─→ _letterboxIntoBuffer(crop, 160×160) → Float32List
      ├─→ ocrInterpreter.run() → [1, 40, N] output
      ├─→ _parseOCROptimized() → List<CharDetection>
      └─→ _processCharacters() → (code, number)
      │
      ▼
LicensePlateResult { fullPlate, code, number, plateBox, croppedPlate, metrics }
      │
      ▼
UI: result card + cropped thumbnail + metrics table
```

### Real-Time Mode

```
Camera (30fps)
      │
      ▼
CameraFrameProcessor.processFrame(CameraImage)
      │
      ├─ [gate: drop if busy or interval too short]
      │
      ├─ CameraImageConverterOptimized.convertAsync()
      │       │
      │       └─ compute(_convertInIsolate) ──→ background isolate
      │               YUV420 → RGB using lookup tables
      │               copyRotate(sensorOrientation)
      │               enforceMaxDimension(720px)
      │           ←── img.Image
      │
      ├─ detector.recognizePlate(convertedImage)  [main isolate]
      │
      ├─ ProcessingState emitted via onStateUpdate
      │
      ▼
PlateResultStabilizer.processResult(result)
      │
      ├─ fuzzy match against current plate
      ├─ increment / reset consecutiveFrames
      ├─ determine PlateStability (detected / confirming / confirmed)
      └─ on first confirmation: haptic + history entry + onPlateConfirmed callback
      │
      ▼
UI setState(): DetectionOverlay + ConfirmedPlateBanner + metrics HUD
```

### Scan LPN Mode

```
Camera (30fps)
      │
      ▼
DetectionOnlyProcessor.processFrame(CameraImage)
      │
      ├─ [gate: drop if busy or interval too short]
      ├─ convertAsync() → img.Image
      ├─ detector.recognizePlate(image) → read plateBox.confidence only
      │
      ├─ if confidence < 0.65 → onFrameResult(box) → live overlay update
      │
      └─ if confidence ≥ 0.65:
              store (image, box) as lastValid
              onPlateDetected(box, confidence) → trigger capture
              │
              ▼
      _triggerCapture()
              │
              ├─ stopStream()
              ├─ detectionProcessor.captureFrame() → CapturedFrame
              ├─ setState(phase = capturing, showFlash = true)
              │
              ▼
      CaptureFlashOverlay.onComplete()
              │
              ▼
      _runOcr()
              │
              ├─ detector.recognizePlate(capturedFrame.fullImage)  ← full pipeline
              ├─ encode croppedPlate → PNG bytes (compute)
              └─ setState(phase = result, ocrResult = result)
              │
              ▼
      ScanResultCard displayed
```

---

## 15. Key Design Decisions & R&D Notes

### Why call `recognizePlate()` twice in Scan LPN?

`DetectionOnlyProcessor` calls the full pipeline but discards OCR output. This was chosen over implementing a separate detection-only code path because:
1. It avoids duplicating detection model inference logic from the locked `LicensePlateDetectorMetricNew`.
2. The overhead is acceptable — the detection-only phase runs on downsampled frames with a `minIntervalMs` gate.
3. The architecture stays clean: one pipeline class, used uniformly.

The second call (OCR pass) uses the full-resolution frozen frame for maximum character recognition accuracy.

### Why `BoxFit.cover` vs `BoxFit.contain` matters

Real-time mode uses `BoxFit.cover` for the camera preview (fills the screen, crops edges). The detection overlay's coordinate mapping must account for the portion of the image that is cropped off-screen.

Scan LPN's `FrozenFrameView` uses `BoxFit.contain` (shows the whole image with letterboxing). The bounding box painter uses the opposite math — offsetting inward rather than outward.

Getting this wrong causes bounding boxes to appear in the wrong position. The two mappers (`PreviewCoordinateMapper` for cover, `_FrozenBoxPainter._map()` for contain) are the canonical references.

### Why pre-allocate TFLite buffers?

`Float32List` allocation for 640×640×3 = ~4.9MB per inference call. At 2.5 FPS that is ~12MB/s of allocation pressure, causing GC pauses. Pre-allocating once in `_preallocateBuffers()` and reusing eliminates this. The output buffer is reset with a loop (`_resetOutputBuffer()`) which is faster than re-allocation.

### Why `compute()` for YUV conversion but not TFLite inference?

`compute()` spawns a Dart isolate (separate memory heap). TFLite interpreters allocate native memory (via FFI) that is bound to the isolate that created them — they cannot be used from a different isolate. Image conversion is pure Dart operations on `Uint8List` + `img.Image`, which are fully serializable and safe to run in any isolate.

### Fuzzy plate matching rationale

OCR models frequently produce 1-character differences on the same plate across consecutive frames due to:
- Motion blur on the middle character
- Lighting variation on edges
- Different cropping from frame-to-frame affecting a border character

Allowing 1 edit distance (Hamming distance on same-length strings) absorbs this jitter without allowing false confirmations of genuinely different plates (which typically differ by 2+ characters).

### GPU delegate and model precision

`isPrecisionLossAllowed: true` on `GpuDelegateOptionsV2` permits FP16 execution on the GPU even though the model is FP32. This is a ~1.5–2× speed improvement with negligible accuracy impact for detection/OCR tasks. Set to `false` if you encounter incorrect detections on specific hardware.

---

## 16. Integration Guide for Production Apps

This section documents how to extract and integrate each component.

### Minimal Integration: Just the Pipeline

The minimum required files to run the LPR pipeline in another app:

```
services/license_plate_detector_metric_new.dart
services/model_service_manager.dart
config/pipeline_config.dart
assets/models/detection_model_float32.tflite
assets/models/ocr_model_float32.tflite
```

Usage:
```dart
final manager = ModelServiceManager();
final detector = await manager.getOrLoadDetector(
  PipelineType.fullPipelineFloat32_640,
  delegateType: DelegateType.gpu,
);

final img.Image image = /* your image */;
final LicensePlateResult? result = await detector.recognizePlate(image);

if (result != null) {
  print(result.fullPlate);  // e.g. "ABC-1234"
  print(result.code);       // e.g. "ABC"
  print(result.number);     // e.g. "1234"
}
```

### Real-Time Integration

Additional files needed on top of the minimal set:

```
services/camera_frame_processor.dart
services/plate_result_stabilizer.dart
utils/image_conversion_optimized.dart
utils/image_conversion.dart
config/realtime_config.dart
```

The `CameraFrameProcessor` and `PlateResultStabilizer` can be dropped into any screen that already has a `CameraController`. Connect them as shown in `real_time_lpr_screen.dart`.

### Scan LPN Integration

Additional files needed:

```
services/detection_only_processor.dart
widgets/scan_result_overlay.dart
screens/scan_lpn_screen.dart   ← or adapt the logic into your own screen
```

`ScanLpnScreen` can be launched directly from any existing Navigator. It is fully self-contained and returns via `Navigator.pop()` when done. If you need to receive the result back, replace `_onDone()` with a `Navigator.pop(context, _ocrResult)` and read the result with `await Navigator.push(...)`.

### Customizing Thresholds for Production

Adjust these values before integrating — the R&D defaults are tuned for exploration, not production:

```dart
// In RealtimeConfig (real-time mode)
static const int confirmationFrameCount = 5;  // Higher = fewer false positives
static const int minFrameIntervalMs = 200;    // Lower FPS = less battery drain

// In ScanLpnScreen._startScanning() — CaptureQualityConfig (scan mode)
const CaptureQualityConfig(
  minConfidence: 0.65,           // Raise for stricter confidence gate
  requiredStableFrames: 5,       // More frames = sharper capture, slower trigger
  maxCentreMoveFraction: 0.06,   // Lower = reject more hand movement
  maxAreaChangeFraction: 0.04,   // Lower = reject more zoom drift
  minPlateAreaFraction: 0.01,    // Higher = require plate to be closer
)

// In LicensePlateDetectorMetricNew (pipeline)
static const double detConfThreshold = 0.50;  // Raise for fewer false detections
static const double ocrConfThreshold = 0.25;  // Raise for fewer character errors
```

### Thread Safety

`LicensePlateDetectorMetricNew` is **not thread-safe**. Its TFLite interpreters must be called from a single isolate (the main isolate). Do not share a single detector instance across multiple `CameraFrameProcessor` instances.

`ModelServiceManager` is a singleton and handles concurrent load requests via stream subscription — it is safe to call `getOrLoadDetector()` from multiple places simultaneously.

---

## 17. Known Limitations & Future Work

### Current Limitations

| Limitation | Detail |
|---|---|
| Single plate detection | Pipeline returns only the highest-confidence plate per frame. Multi-plate scenes use only the best detection. |
| Latin plates only | OCR model trained on `0–9` + `A–Z`. Arabic, Cyrillic, or locale-specific plates are not supported. |
| Fixed plate format | `_processCharacters()` splits letters and numbers; does not handle locale-specific plate formats (e.g. plates with spaces, dots, or multi-row layouts). |
| Horizontal plates only | The model is not trained on vertical plate orientations. |
| No persistence | History and results are in-memory only; lost on app restart. |
| `BoundingBoxPainter` stub | In `license_plate_screen_metric_new.dart`, the box painter's coordinate scaling is not fully implemented. |
| Portrait-only | `SystemChrome.setPreferredOrientations` forces portrait in both real-time and scan modes. |

### Potential R&D Directions

- **Float16 model variant:** Add `PipelineType.fullPipelineFloat16_640` to benchmark speed vs accuracy trade-off.
- **Int8 quantized model:** Add a `fastPipelineInt8_320` variant for low-end devices.
- **Plate format post-processing:** Add locale-aware regex cleaning after OCR (e.g. UAE plate format validator).
- **Multi-plate NMS:** Extend the detection pass to return all plates above threshold, not just the best.
- **Plate angle correction:** Add a perspective-correction step between detection crop and OCR to handle skewed plates.
- **On-device result persistence:** Add SQLite or Hive storage for scan history across sessions.
- **Confidence calibration:** Run the models against a labeled dataset to tune per-device threshold values.
- **Camera resolution experiment:** Test `ResolutionPreset.ultraHigh` for the Scan LPN OCR pass vs current `high`.
- **Model warm-up inference:** Run a single black frame through the model after loading to pre-warm the GPU execution path, reducing first-frame latency.

---

## 18. Revision History

### R&D Session 2 — Scan LPN Quality Gates

**Problem:** Scan LPN was capturing distorted / blurry frames, causing OCR to consistently fail. The original implementation triggered capture on the **first frame** that met the confidence threshold. At 100 ms minimum intervals plus ~400 ms inference time per frame, the effective capture rate was fast enough to catch motion-blurred frames before the camera had settled and auto-focused.

**Root cause analysis:**

Two bugs identified:

**Bug 1 — No frame stability check.** The original `DetectionOnlyProcessor` had a single gate: `confidence ≥ 0.65`. A single confident detection on a motion-blurred frame was sufficient to trigger capture. There was no requirement that the plate be in the same position across multiple frames.

**Bug 2 — Gates were correct but thresholds were miscalibrated.** A second iteration introduced `_StabilityTracker` with movement and area-change gates, but the defaults were tuned too tightly for handheld use:

```
maxCentreMoveFraction: 0.04  ← 4% of image width
maxAreaChangeFraction: 0.03  ← 3% of image area
requiredStableFrames:  4
```

At ~2–3 effective FPS (100 ms interval + ~400 ms inference), a normal handheld phone drifts 6–10% of image width between processed frames even when held "still". The tracker was resetting on every single frame so `stableCount` never reached 4 — capture never fired.

**Fix applied:**

The quality gate defaults were recalibrated for real handheld conditions:

```dart
const CaptureQualityConfig(
  minConfidence: 0.55,           // Slightly lower — gates do the quality work
  requiredStableFrames: 3,       // ~1.5 s at current effective FPS
  maxCentreMoveFraction: 0.08,   // 8% — fits normal hand tremor
  maxAreaChangeFraction: 0.06,   // 6% — allows minor zoom drift
  minPlateAreaFraction: 0.005,   // Very permissive — rejects only tiny detections
)
```

Additional structural fixes:

- `_isProcessing = false` and `_lastEndTime` are now set **before** callbacks fire, preventing a race where a rapid second frame could be gated out while the capture callback was still on the call stack.
- `_onCaptureReady` in the screen now sets `_phase = ScanPhase.capturing` as its **first** action, making the `_phase != ScanPhase.scanning` guard on subsequent stray callbacks immediately effective.
- The `_softReset` path (no detection this frame) now correctly clears both run counters and the position baseline. Previously it only cleared the baseline, wasting one stable-frame slot on the next detection.
- The capture callback was renamed from `onPlateDetected` → `onReadyToCapture` and the `captureFrame()` async method was eliminated. The `CapturedFrame` is now passed directly in the callback, removing an async gap where the stored frame could be overwritten.

**Model files Not included:** The model files are not included in the repo. When supplying your own, name it `detection_model_float32.tflite`, `ocr_model_float32.tflite` and update the asset path in `PipelineConfig` accordingly.