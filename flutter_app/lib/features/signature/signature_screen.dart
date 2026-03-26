import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class SignatureScreen extends StatefulWidget {
  const SignatureScreen({super.key});

  @override
  State<SignatureScreen> createState() => _SignatureScreenState();
}

class _SignatureScreenState extends State<SignatureScreen> {
  final List<_Stroke> _strokes = [];
  _Stroke? _currentStroke;
  final _repaintKey = GlobalKey();
  bool _isSaving = false;

  // Track whether anything has been drawn
  bool get _hasSignature => _strokes.isNotEmpty || _currentStroke != null;

  void _onPanStart(DragStartDetails d) {
    setState(() {
      _currentStroke = _Stroke([d.localPosition]);
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_currentStroke == null) return;
    // Use RenderBox to get local position from global
    setState(() {
      _currentStroke!.points.add(d.localPosition);
    });
  }

  void _onPanEnd(DragEndDetails d) {
    if (_currentStroke == null) return;
    setState(() {
      _strokes.add(_currentStroke!);
      _currentStroke = null;
    });
  }

  void _clear() => setState(() { _strokes.clear(); _currentStroke = null; });

  Future<void> _confirm() async {
    if (!_hasSignature) return;
    setState(() => _isSaving = true);

    try {
      // Capture the widget as an image at 2x device pixel ratio for quality
      final boundary = _repaintKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();

      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/signatures/${const Uuid().v4()}.png';
      await Directory('${dir.path}/signatures').create(recursive: true);
      await File(path).writeAsBytes(bytes);

      if (mounted) Navigator.pop(context, path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save signature: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Use landscape orientation for signature pad
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customer Signature'),
        actions: [
          TextButton(
            onPressed: _hasSignature ? _clear : null,
            child: const Text('Clear'),
          ),
        ],
      ),
      body: Column(
        children: [
          // Instruction banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Text(
              'Please sign in the area below',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
                fontSize: 14,
              ),
            ),
          ),

          // Signature pad
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: RepaintBoundary(
                  key: _repaintKey,
                  child: GestureDetector(
                    onPanStart: _onPanStart,
                    onPanUpdate: _onPanUpdate,
                    onPanEnd: _onPanEnd,
                    child: CustomPaint(
                      painter: _SignaturePainter(
                        strokes: _strokes,
                        currentStroke: _currentStroke,
                      ),
                      child: SizedBox.expand(
                        child: _hasSignature
                            ? null
                            : Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.draw_outlined,
                                        size: 36,
                                        color: Colors.grey.shade300),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Sign here',
                                      style: TextStyle(
                                        color: Colors.grey.shade400,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Bottom bar
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(52)),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: (_hasSignature && !_isSaving) ? _confirm : null,
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52)),
                      child: _isSaving
                          ? const SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Confirm Signature',
                              style: TextStyle(fontSize: 16)),
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

/// Holds a single continuous stroke (pen-down to pen-up).
class _Stroke {
  final List<Offset> points;
  _Stroke(this.points);
}

/// Custom painter for smooth, 60fps signature rendering.
///
/// Uses quadratic bezier curves through midpoints to produce smooth strokes
/// instead of straight line segments between touch points.
class _SignaturePainter extends CustomPainter {
  final List<_Stroke> strokes;
  final _Stroke? currentStroke;

  _SignaturePainter({required this.strokes, this.currentStroke});

  @override
  void paint(Canvas canvas, Size size) {
    // White background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Colors.white,
    );

    final paint = Paint()
      ..color = const Color(0xFF1A1A2E)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (final stroke in strokes) {
      _drawStroke(canvas, stroke, paint);
    }
    if (currentStroke != null) {
      _drawStroke(canvas, currentStroke!, paint);
    }
  }

  void _drawStroke(Canvas canvas, _Stroke stroke, Paint paint) {
    final pts = stroke.points;
    if (pts.isEmpty) return;

    final path = Path();

    if (pts.length == 1) {
      // Single tap — draw a dot
      canvas.drawCircle(pts[0], 1.5, paint..style = PaintingStyle.fill);
      paint.style = PaintingStyle.stroke;
      return;
    }

    path.moveTo(pts[0].dx, pts[0].dy);

    if (pts.length == 2) {
      path.lineTo(pts[1].dx, pts[1].dy);
    } else {
      // Smooth quadratic bezier through midpoints
      for (int i = 0; i < pts.length - 1; i++) {
        final mid = Offset(
          (pts[i].dx + pts[i + 1].dx) / 2,
          (pts[i].dy + pts[i + 1].dy) / 2,
        );
        if (i == 0) {
          path.lineTo(mid.dx, mid.dy);
        } else {
          path.quadraticBezierTo(
            pts[i].dx, pts[i].dy, mid.dx, mid.dy);
        }
      }
      // Last segment to the final point
      path.lineTo(pts.last.dx, pts.last.dy);
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SignaturePainter old) =>
      old.strokes != strokes || old.currentStroke != currentStroke;
}
