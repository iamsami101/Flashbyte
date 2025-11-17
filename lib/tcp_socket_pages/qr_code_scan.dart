import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QrCodeScanPage extends StatefulWidget {
  final void Function(String value) onScanned;
  const QrCodeScanPage({super.key, required this.onScanned});

  @override
  State<QrCodeScanPage> createState() => _QrCodeScanPageState();
}

class _QrCodeScanPageState extends State<QrCodeScanPage> {
  bool cameraFlip = false;
  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: [BarcodeFormat.qrCode],
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
          child: Column(
            children: [
              Expanded(
                child: SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.8,
                  child: ClipRRect(
                    borderRadius: BorderRadiusGeometry.circular(20),
                    child: Stack(
                      children: [
                        MobileScanner(
                          controller: controller,
                          onDetect: (barcodes) {
                            final barcode = barcodes.barcodes.first;
                            widget.onScanned(barcode.rawValue!);
                            HapticFeedback.vibrate();
                          },
                        ),
                        QrScannerOverlay(cutOutSize: 250),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(height: 20),
              Card(
                margin: EdgeInsets.zero,
                child: InkWell(
                  onTap: () {
                    setState(() {
                      controller.switchCamera();
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(13),
                    child: Row(
                      spacing: 20,
                      children: [
                        Icon(Icons.flip_camera_android),
                        Text("Flip Camera"),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class QrScannerOverlay extends StatelessWidget {
  final double cutOutSize;

  const QrScannerOverlay({super.key, required this.cutOutSize});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ColorFiltered(
          colorFilter: const ColorFilter.mode(Colors.black54, BlendMode.srcOut),
          child: Stack(
            children: [
              Container(
                decoration: const BoxDecoration(
                  color: Colors.black,
                  backgroundBlendMode: BlendMode.dstOut,
                ),
              ),
              Align(
                alignment: Alignment.center,
                child: Container(
                  width: cutOutSize,
                  height: cutOutSize,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Optional border around the transparent area
        Align(
          alignment: Alignment.center,
          child: Container(
            width: cutOutSize,
            height: cutOutSize,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }
}
