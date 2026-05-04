import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as imglib;

typedef LandmarkCallback =
    void Function(List<List<double>> landmarks, int width, int height);
typedef AnchorCallback =
    void Function(
      Uint8List jpeg,
      List<List<double>> landmarks,
      int width,
      int height,
    );

class CameraService {
  CameraController? _controller;

  final _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: true,
      enableClassification: false,
      enableTracking: false,
      performanceMode: FaceDetectorMode
          .fast, // Kaşlar ve ince mimikler için accurate kalmalı
    ),
  );

  bool _streaming = false;
  bool _processing = false;
  bool pendingAnchorRequest = false;

  CameraController? get controller => _controller;
  bool get isInitialized => _controller?.value.isInitialized ?? false;

  Future<void> initialize() async {
    final cameras = await availableCameras();
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.bgra8888,
    );
    await _controller!.initialize();
  }

  Future<void> startNanoBandStream({
    required LandmarkCallback onLandmarks,
    required AnchorCallback onAnchor,
  }) async {
    if (_controller == null || _streaming) return;
    _streaming = true;

    await _controller!.startImageStream((CameraImage image) async {
      if (_processing) return;
      _processing = true;
      try {
        // DÖNDÜRME SİLİNDİ: rotation0deg yapıldı.
        final inputImage = InputImage.fromBytes(
          bytes: image.planes[0].bytes,
          metadata: InputImageMetadata(
            size: Size(image.width.toDouble(), image.height.toDouble()),
            rotation: InputImageRotation.rotation0deg,
            format: InputImageFormat.bgra8888,
            bytesPerRow: image.planes[0].bytesPerRow,
          ),
        );

        final faces = await _detector.processImage(inputImage);
        if (faces.isEmpty) return;

        final rawLms = _extractContours(faces.first);
        if (rawLms.isEmpty) return;

        // DÖNDÜRME OLMADIĞI İÇİN YER DEĞİŞTİRME YOK: Doğrudan width ve height alıyoruz.
        double currentWidth = image.width.toDouble();
        double currentHeight = image.height.toDouble();

        double scale = 480.0 / currentWidth;
        int scaledW = 480;
        int scaledH = (currentHeight * scale).toInt();

        // Aynalama (Flip) X Eksenini Ters Çevirme
        final lms = rawLms.map((pt) {
          double x = pt[0] * scale;
          double y = pt[1] * scale;
          return [scaledW - x, y];
        }).toList();

        if (pendingAnchorRequest) {
          pendingAnchorRequest = false;
          final jpeg = _encodeJpeg(image);
          if (jpeg != null) onAnchor(jpeg, lms, scaledW, scaledH);
        } else {
          onLandmarks(lms, scaledW, scaledH);
        }
      } finally {
        _processing = false;
      }
    });
  }

  Future<void> startStandardStream({
    required void Function(Uint8List jpeg) onFrame,
  }) async {
    if (_controller == null || _streaming) return;
    _streaming = true;
    int count = 0;

    await _controller!.startImageStream((CameraImage image) async {
      count++;
      if (count % 3 != 0) return;
      if (_processing) return;
      _processing = true;
      try {
        final jpeg = _encodeJpeg(image, quality: 50);
        if (jpeg != null) onFrame(jpeg);
      } finally {
        _processing = false;
      }
    });
  }

  Future<void> stopStream() async {
    if (!_streaming) return;
    _streaming = false;
    _processing = false;
    await _controller?.stopImageStream();
  }

  Future<void> dispose() async {
    _streaming = false;
    await _detector.close();
    await _controller?.dispose();
    _controller = null;
  }

  List<List<double>> _extractContours(Face face) {
    final result = <List<double>>[];
    for (final type in FaceContourType.values) {
      final contour = face.contours[type];
      if (contour == null) continue;
      for (final pt in contour.points) {
        result.add([pt.x.toDouble(), pt.y.toDouble()]);
      }
    }
    return result;
  }

  Uint8List? _encodeJpeg(CameraImage image, {int quality = 70}) {
    try {
      final int width = image.width;
      final int height = image.height;
      final int bytesPerRow = image.planes[0].bytesPerRow;
      final Uint8List rawBytes = image.planes[0].bytes;

      final Uint8List cleanBytes = Uint8List(width * height * 4);
      if (bytesPerRow == width * 4) {
        cleanBytes.setRange(0, rawBytes.length, rawBytes);
      } else {
        // iOS Padding temizliği (Renklerin doğru çıkmasını sağlayan kod)
        for (int y = 0; y < height; y++) {
          int srcOffset = y * bytesPerRow;
          int dstOffset = y * width * 4;
          cleanBytes.setRange(
            dstOffset,
            dstOffset + (width * 4),
            rawBytes.sublist(srcOffset, srcOffset + (width * 4)),
          );
        }
      }

      imglib.Image decoded = imglib.Image.fromBytes(
        width: width,
        height: height,
        bytes: cleanBytes.buffer,
        order: imglib.ChannelOrder.bgra,
      );

      // ROTASYON TAMAMEN SİLİNDİ!

      // Sadece Aynalama (Ekranda kendini ayna gibi görebilmen ve noktaların uyuşması için)
      decoded = imglib.flipHorizontal(decoded);

      final resized = imglib.copyResize(decoded, width: 480);
      return Uint8List.fromList(imglib.encodeJpg(resized, quality: quality));
    } catch (e) {
      print("❌ JPEG Encode Hatası: $e");
      return null;
    }
  }
}
