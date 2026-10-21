import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/evidence_store.dart';
import '../ui/theme.dart';
import '../utils/format.dart';

/// Fotos de evidencia de una carrera a pantalla completa. Con ▶ se pasan
/// solas (como un vídeo a cámara rápida).
class EvidenceViewerScreen extends StatefulWidget {
  final List<EvidenceShot> shots;
  final int initial;
  final bool autoplay;

  const EvidenceViewerScreen({
    super.key,
    required this.shots,
    this.initial = 0,
    this.autoplay = false,
  });

  @override
  State<EvidenceViewerScreen> createState() => _EvidenceViewerScreenState();
}

class _EvidenceViewerScreenState extends State<EvidenceViewerScreen> {
  late final PageController _pages = PageController(
    initialPage: widget.initial,
  );
  late int _index = widget.initial;
  Timer? _timer;

  /// Segundos que se muestra cada foto al reproducir.
  double _speed = 0.8;

  @override
  void initState() {
    super.initState();
    if (widget.autoplay) _play();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pages.dispose();
    super.dispose();
  }

  bool get _playing => _timer != null;

  void _play() {
    if (_index >= widget.shots.length - 1) _go(0);
    _timer = Timer.periodic(Duration(milliseconds: (_speed * 1000).round()), (
      _,
    ) {
      if (_index >= widget.shots.length - 1) {
        _stop();
      } else {
        _go(_index + 1);
      }
    });
    setState(() {});
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    if (mounted) setState(() {});
  }

  void _go(int i) {
    _pages.jumpToPage(i);
    setState(() => _index = i);
  }

  Future<void> _share() async {
    final s = widget.shots[_index];
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(s.file.path)],
        text:
            'Taxiff · ${s.reason.label} · ${formatDate(s.time)} ${formatTime(s.time)}',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shots = widget.shots;
    final s = shots[_index];
    final first = shots.first.time;
    return Theme(
      data: buildTheme(Brightness.dark),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.reason.label, style: const TextStyle(fontSize: 18)),
              Text(
                '${formatTime(s.time)} · '
                '+${formatDuration(s.time.difference(first))} · '
                '${_index + 1}/${shots.length}',
                style: const TextStyle(fontSize: 13, color: Colors.white60),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Compartir foto',
              icon: const Icon(Icons.share_outlined),
              onPressed: _share,
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: PageView.builder(
                  controller: _pages,
                  itemCount: shots.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (_, i) => InteractiveViewer(
                    maxScale: 4,
                    child: Center(
                      child: Image.file(
                        shots[i].file,
                        gaplessPlayback: true,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ),
              // Marcas de eventos sobre la línea de tiempo.
              SizedBox(
                height: 14,
                child: LayoutBuilder(
                  builder: (context, c) {
                    final total = shots.last.time
                        .difference(first)
                        .inMilliseconds;
                    return Stack(
                      children: [
                        for (final sh in shots)
                          if (sh.reason != ShotReason.periodic)
                            Positioned(
                              left:
                                  24 +
                                  (c.maxWidth - 48) *
                                      (total == 0
                                          ? 0
                                          : sh.time
                                                    .difference(first)
                                                    .inMilliseconds /
                                                total),
                              top: 3,
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: _reasonColor(sh.reason),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                      ],
                    );
                  },
                ),
              ),
              Slider(
                value: _index.toDouble(),
                max: (shots.length - 1).toDouble().clamp(1, double.infinity),
                onChanged: shots.length < 2
                    ? null
                    : (v) {
                        _stop();
                        _go(v.round());
                      },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous_rounded),
                      onPressed: _index == 0 ? null : () => _go(_index - 1),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: shots.length < 2
                          ? null
                          : (_playing ? _stop : _play),
                      icon: Icon(
                        _playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                      label: Text(_playing ? 'Pausa' : 'Reproducir'),
                    ),
                    const SizedBox(width: 8),
                    PopupMenuButton<double>(
                      tooltip: 'Velocidad',
                      initialValue: _speed,
                      onSelected: (v) {
                        setState(() => _speed = v);
                        if (_playing) {
                          _stop();
                          _play();
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 1.5, child: Text('Lento')),
                        PopupMenuItem(value: 0.8, child: Text('Normal')),
                        PopupMenuItem(value: 0.3, child: Text('Rápido')),
                      ],
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.speed_rounded),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.skip_next_rounded),
                      onPressed: _index >= shots.length - 1
                          ? null
                          : () => _go(_index + 1),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _reasonColor(ShotReason r) => switch (r) {
  ShotReason.start => AppColors.accent,
  ShotReason.entered => AppColors.passenger,
  ShotReason.seatChange => AppColors.info,
  ShotReason.exited => const Color(0xFF8E8E93),
  ShotReason.periodic => Colors.white38,
};

/// Tarjeta "Evidencias" del detalle de carrera: miniaturas y botón para
/// verlas como vídeo.
class EvidenceCard extends StatelessWidget {
  final String? dir;
  const EvidenceCard({super.key, required this.dir});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<EvidenceShot>>(
      future: EvidenceStore.list(dir),
      builder: (context, snap) {
        final shots = snap.data ?? const [];
        if (shots.isEmpty) return const SizedBox.shrink();
        final s = Surfaces.of(context);
        void open(int i, {bool play = false}) => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                EvidenceViewerScreen(shots: shots, initial: i, autoplay: play),
          ),
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Material(
            color: s.card,
            borderRadius: BorderRadius.circular(26),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Evidencias',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        '${shots.length} fotos',
                        style: TextStyle(fontSize: 13, color: s.textSecondary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 168,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: shots.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, i) => GestureDetector(
                        onTap: () => open(i),
                        child: SizedBox(
                          width: 96,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.file(
                                  shots[i].file,
                                  width: 96,
                                  height: 128,
                                  fit: BoxFit.cover,
                                  cacheWidth: 200,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                      color: _reasonColor(shots[i].reason),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    formatTime(shots[i].time),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: s.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => open(0, play: true),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Ver la carrera como vídeo'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
