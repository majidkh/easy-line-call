// Home screen: logo + title on top, court format picker, then the two
// feeds at the bottom. Everything downstream behaves the same — only the
// frame source (and the judged lines) differ.
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'calibrate_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _doubles = true;
  bool _exportFilm = false;

  Future<void> _processVideo() async {
    try {
      final picked = await ImagePicker()
          .pickVideo(source: ImageSource.gallery);
      if (!mounted || picked == null) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CalibratePage.video(
              videoPath: picked.path,
              doubles: _doubles,
              exportFilm: _exportFilm),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not pick a video: $e')),
      );
    }
  }

  void _liveFeed() {
    showModalBottomSheet(
      context: context,
      builder: (_) => _CameraPicker(
        onPick: (cam) {
          Navigator.pop(context);
          if (!mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CalibratePage.live(
                  doubles: _doubles,
                  camera: cam,
                  exportFilm: _exportFilm),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Compact on phones (landscape height ~375pt, portrait
            // width ~390pt): everything shrinks so the page fits
            // without overflow.
            final compact = constraints.maxWidth < 500 ||
                constraints.maxHeight < 500;
            final titleSize = compact ? 24.0 : 44.0;
            final logoSize = compact ? 38.0 : 64.0;
            final labelSize = compact ? 14.0 : 16.0;
            final buttonH = compact ? 50.0 : 64.0;
            final buttonFont = compact ? 16.0 : 20.0;
            final buttonIcon = compact ? 22.0 : 26.0;
            return Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: compact ? 20 : 32),
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  // Logo + title.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.sports_tennis,
                          size: logoSize,
                          color: Colors.purpleAccent),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          'Easy Line Call',
                          style: TextStyle(
                            fontSize: titleSize,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(flex: 2),
                  // Court format — decides which lines calls are judged on.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Court:',
                          style: TextStyle(
                              color: Colors.white70,
                              fontSize: labelSize)),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.white
                                .withValues(alpha: 0.05),
                            border:
                                Border.all(color: Colors.white10),
                            borderRadius:
                                BorderRadius.circular(12),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<bool>(
                              value: _doubles,
                              dropdownColor:
                                  const Color(0xFF1E1E1E),
                              icon: const Icon(Icons.expand_more,
                                  color: Colors.purpleAccent),
                              style: TextStyle(
                                  fontSize: labelSize,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white),
                              items: const [
                                DropdownMenuItem(
                                    value: true,
                                    child: Text('Doubles')),
                                DropdownMenuItem(
                                    value: false,
                                    child: Text('Singles')),
                              ],
                              onChanged: (v) {
                                if (v != null) {
                                  setState(
                                      () => _doubles = v);
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  // Annotated-film export: same FPS/sound, lines +
                  // bounces + balls drawn in, written to an output/
                  // folder.
                  CheckboxListTile(
                    value: _exportFilm,
                    dense: compact,
                    visualDensity: compact
                        ? VisualDensity.compact
                        : VisualDensity.standard,
                    onChanged: (v) =>
                        setState(() => _exportFilm = v ?? false),
                    title: Text('Export annotated film',
                        style: TextStyle(fontSize: labelSize)),
                    subtitle: Text(
                        'same quality, FPS and sound into output/',
                        style: TextStyle(
                            color: Colors.white70,
                            fontSize: labelSize - 2)),
                    controlAffinity:
                        ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                  SizedBox(height: compact ? 6 : 8),
                  // The two feeds.
                  SizedBox(
                    width: double.infinity,
                    height: buttonH,
                    child: ElevatedButton.icon(
                      onPressed: _processVideo,
                      icon: Icon(Icons.movie_outlined,
                          size: buttonIcon),
                      label: Text('process video',
                          style: TextStyle(
                              fontSize: buttonFont,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                  SizedBox(height: compact ? 10 : 14),
                  SizedBox(
                    width: double.infinity,
                    height: buttonH,
                    child: OutlinedButton.icon(
                      onPressed: _liveFeed,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.purpleAccent,
                        side: const BorderSide(
                            color: Colors.purpleAccent,
                            width: 1.5),
                        shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(12)),
                      ),
                      icon: Icon(Icons.videocam_outlined,
                          size: buttonIcon),
                      label: Text('live feed',
                          style: TextStyle(
                              fontSize: buttonFont,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                  SizedBox(height: compact ? 12 : 24),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Front/back camera choice for the live feed. With a single camera the
/// choice is skipped and the lone camera starts directly.
class _CameraPicker extends StatelessWidget {
  final void Function(CameraDescription?) onPick;
  const _CameraPicker({required this.onPick});

  String _label(CameraDescription c) {
    switch (c.lensDirection) {
      case CameraLensDirection.front:
        return 'Front camera';
      case CameraLensDirection.back:
        return 'Back camera';
      case CameraLensDirection.external:
        return 'External camera (${c.name})';
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<List<CameraDescription>>(
        future: availableCameras(),
        builder: (context, snap) {
          final cams = snap.data ?? const <CameraDescription>[];
          if (snap.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 140,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (cams.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No camera found on this device.',
                  textAlign: TextAlign.center),
            );
          }
          if (cams.length == 1) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              onPick(cams.first);
            });
            return const SizedBox(
              height: 140,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text('Choose a camera for the live feed',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              for (final c in cams)
                ListTile(
                  leading: Icon(
                      c.lensDirection == CameraLensDirection.front
                          ? Icons.camera_front_outlined
                          : Icons.camera_rear_outlined),
                  title: Text(_label(c)),
                  subtitle: Text(c.name,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.white38)),
                  onTap: () => onPick(c),
                ),
              const SizedBox(height: 12),
            ],
          );
        },
      ),
    );
  }
}
