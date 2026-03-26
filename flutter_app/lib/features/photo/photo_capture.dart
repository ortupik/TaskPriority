import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../../core/app_config.dart';
import '../../core/storage/app_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PhotoCaptureScreen extends ConsumerStatefulWidget {
  final String jobId;
  final String fieldId;

  const PhotoCaptureScreen({super.key, required this.jobId, required this.fieldId});

  @override
  ConsumerState<PhotoCaptureScreen> createState() => _PhotoCaptureScreenState();
}

class _PhotoCaptureScreenState extends ConsumerState<PhotoCaptureScreen> {
  CameraController? _ctrl;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isCapturing = false;
  String? _capturedPath;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    // Request permission
    final status = await Permission.camera.request();
    if (status.isDenied) {
      setState(() => _error = 'Camera permission denied.');
      return;
    }

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _error = 'No camera found on this device.');
        return;
      }

      _ctrl = CameraController(
        _cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _ctrl!.initialize();
      if (mounted) setState(() => _isInitialized = true);
    } catch (e) {
      setState(() => _error = 'Failed to initialize camera: $e');
    }
  }

  Future<void> _capture() async {
    if (_ctrl == null || !_isInitialized || _isCapturing) return;
    setState(() => _isCapturing = true);

    try {
      final xFile = await _ctrl!.takePicture();
      final processed = await _processImage(xFile.path);
      if (mounted) setState(() { _capturedPath = processed; _isCapturing = false; });
    } catch (e) {
      if (mounted) setState(() { _isCapturing = false; _error = 'Capture failed: $e'; });
    }
  }

  /// Process captured image:
  ///   1. Read raw bytes
  ///   2. Decode + auto-rotate (EXIF orientation)
  ///   3. Resize to max 1200px longest edge
  ///   4. Burn timestamp overlay
  ///   5. Re-encode as JPEG at 80% quality
  ///   6. Save to app documents directory
  Future<String> _processImage(String sourcePath) async {
    final bytes = await File(sourcePath).readAsBytes();
    img.Image? image = img.decodeImage(bytes);
    if (image == null) throw Exception('Failed to decode image');

    // 1. EXIF orientation correction (image package handles this)
    image = img.bakeOrientation(image);

    // 2. Resize — preserve aspect ratio
    final maxEdge = AppConfig.photoMaxLongestEdgePx;
    if (image.width > maxEdge || image.height > maxEdge) {
      if (image.width >= image.height) {
        image = img.copyResize(image, width: maxEdge, interpolation: img.Interpolation.linear);
      } else {
        image = img.copyResize(image, height: maxEdge, interpolation: img.Interpolation.linear);
      }
    }

    // 3. Burn timestamp overlay into image pixels
    image = _burnTimestamp(image);

    // 4. Encode to JPEG
    final jpegBytes = img.encodeJpg(image, quality: AppConfig.photoJpegQuality);

    // 5. Save
    final dir = await getApplicationDocumentsDirectory();
    final id = const Uuid().v4();
    final outPath = '${dir.path}/photos/$id.jpg';
    await Directory('${dir.path}/photos').create(recursive: true);
    await File(outPath).writeAsBytes(jpegBytes);

    // 6. Enqueue for upload
    await _enqueueForUpload(outPath);

    return outPath;
  }

  img.Image _burnTimestamp(img.Image image) {
    final now = DateTime.now();
    final stamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(now);

    // Draw semi-transparent black bar at bottom
    final barHeight = (image.height * 0.06).round().clamp(24, 60);
    final barY = image.height - barHeight;

    for (int y = barY; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final orig = image.getPixel(x, y);
        // Darken by 60%
        final r = (img.getRed(orig) * 0.4).round();
        final g = (img.getGreen(orig) * 0.4).round();
        final b = (img.getBlue(orig) * 0.4).round();
        image.setPixel(x, y, img.getColor(r, g, b));
      }
    }

    // Draw text (simplified — image package bitmap font)
    img.drawString(
      image,
      img.arial_24,
      10, barY + (barHeight - 24) ~/ 2,
      stamp,
      color: img.getColor(255, 255, 255),
    );

    return image;
  }

  Future<void> _enqueueForUpload(String localPath) async {
    final db = ref.read(appDatabaseProvider);
    await db.enqueuePhoto(PhotoQueueCompanion(
      id: Value(const Uuid().v4()),
      jobId: Value(widget.jobId),
      localPath: Value(localPath),
      checklistFieldId: Value(widget.fieldId),
      capturedAt: Value(DateTime.now()),
      uploadStatus: const Value('pending'),
      createdAt: Value(DateTime.now()),
    ));
  }

  void _retake() => setState(() => _capturedPath = null);

  void _confirm() {
    if (_capturedPath != null) Navigator.pop(context, _capturedPath);
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Camera')),
        body: _ErrorView(message: _error!, onOpenSettings: openAppSettings),
      );
    }

    if (!_isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_capturedPath != null) {
      return _PreviewScreen(
        path: _capturedPath!,
        onRetake: _retake,
        onConfirm: _confirm,
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Camera preview fills screen
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _ctrl!.value.previewSize!.height,
                  height: _ctrl!.value.previewSize!.width,
                  child: CameraPreview(_ctrl!),
                ),
              ),
            ),
            // Top bar
            Positioned(
              top: 0, left: 0, right: 0,
              child: AppBar(
                backgroundColor: Colors.black54,
                title: const Text('Take Photo', style: TextStyle(color: Colors.white)),
                iconTheme: const IconThemeData(color: Colors.white),
              ),
            ),
            // Capture button
            Positioned(
              bottom: 32, left: 0, right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: _capture,
                  child: Container(
                    width: 72, height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 4),
                    ),
                    child: Center(
                      child: Container(
                        width: 56, height: 56,
                        decoration: const BoxDecoration(
                          color: Colors.white, shape: BoxShape.circle),
                        child: _isCapturing
                            ? const Padding(
                                padding: EdgeInsets.all(14),
                                child: CircularProgressIndicator(
                                    strokeWidth: 3, color: Colors.black),
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewScreen extends StatelessWidget {
  final String path;
  final VoidCallback onRetake;
  final VoidCallback onConfirm;

  const _PreviewScreen({
    required this.path,
    required this.onRetake,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        title: const Text('Review Photo', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          Expanded(
            child: Image.file(File(path), fit: BoxFit.contain),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onRetake,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retake'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white),
                        minimumSize: const Size.fromHeight(52),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onConfirm,
                      icon: const Icon(Icons.check),
                      label: const Text('Use Photo'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onOpenSettings;
  const _ErrorView({required this.message, required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.camera_alt, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: onOpenSettings,
              child: const Text('Open Settings'),
            ),
          ],
        ),
      ),
    );
  }
}
