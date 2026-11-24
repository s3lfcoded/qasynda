import 'dart:async';
import 'dart:io' show File;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../cards.dart';
import '../theme.dart';

/// Сканирование карты камерой (артборд 5 «Радиуса»). Примерно раз в секунду делается снимок, текст на нём
/// распознаёт телефон (канал qasynda/ocr: Apple Vision / ML Kit, без сети), снимок сразу удаляется.
/// Номер принимается, когда одинаково прочитан на двух снимках подряд; затем ещё несколько снимков ждём срок.
/// Возвращает ScannedCard через Navigator.pop; null — человек выбрал ручной ввод или распознавания нет.
class CardScanScreen extends StatefulWidget {
  const CardScanScreen({super.key, this.recognize = CardOcr.recognize});

  /// Распознавание текста по пути к снимку; null — недоступно. Подменяется в тестах.
  final Future<List<String>?> Function(String path) recognize;

  @override
  State<CardScanScreen> createState() => _CardScanScreenState();
}

const _dark = Color(0xFF0F1312);
const _onDark = Color(0x24FFFFFF);
const _found = Color(0xFF5FD3BF);

const _ru = {
  'title': 'Сканирование карты',
  'found': 'Номер найден, проверяем срок',
  'hint': 'Поместите карту в рамку лицевой стороной. Номер и срок заполнятся сами',
  'manual': 'Ввести вручную',
  'torchOn': 'Включить фонарик',
  'torchOff': 'Выключить фонарик',
  'noCamera': 'Камера недоступна. Разрешите доступ в настройках или введите данные вручную',
};
const _kk = {
  'title': 'Картаны сканерлеу',
  'found': 'Нөмір табылды, мерзімін тексеріп жатырмыз',
  'hint': 'Картаны жақтауға бет жағымен орналастырыңыз. Нөмір мен мерзім өздігінен толады',
  'manual': 'Қолмен енгізу',
  'torchOn': 'Фонарьды қосу',
  'torchOff': 'Фонарьды өшіру',
  'noCamera': 'Камера қолжетімсіз. Баптауларда рұқсат беріңіз немесе деректерді қолмен енгізіңіз',
};

class _CardScanScreenState extends State<CardScanScreen> with WidgetsBindingObserver {
  static const _every = Duration(seconds: 1);

  final _progress = CardScanProgress();
  CameraController? _camera;
  Timer? _timer;
  bool _failed = false;
  bool _done = false;
  bool _shooting = false;
  bool _torch = false;

  String _t(String key) =>
      (Localizations.localeOf(context).languageCode == 'kk' ? _kk[key] : null) ?? _ru[key]!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _manual());
    } else {
      _start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    super.dispose();
  }

  /// Камеру нужно отпускать в фоне, иначе система отберёт её у приложения.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _stop();
      if (mounted) setState(() => _torch = false);
    } else if (state == AppLifecycleState.resumed && _camera == null && !_done && !_failed) {
      _start();
    }
  }

  Future<void> _start() async {
    CameraController? camera;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw CameraException('no_camera', null);
      final back = cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cameras.first);
      camera = CameraController(back, ResolutionPreset.high, enableAudio: false);
      await camera.initialize();
      // Без этого снимок по умолчанию делается со вспышкой в темноте — раз в секунду.
      await camera.setFlashMode(FlashMode.off);
      if (!mounted || _done) {
        await camera.dispose();
        return;
      }
      setState(() {
        _camera = camera;
        _failed = false;
      });
      _timer = Timer.periodic(_every, (_) => _shoot());
    } on MissingPluginException {
      await camera?.dispose();
      _manual();
    } catch (_) {
      await camera?.dispose();
      if (mounted) setState(() => _failed = true);
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    final camera = _camera;
    _camera = null;
    camera?.dispose();
  }

  Future<void> _shoot() async {
    final camera = _camera;
    if (_shooting || _done || camera == null || !camera.value.isInitialized || camera.value.isTakingPicture) return;
    _shooting = true;
    String? path;
    try {
      path = (await camera.takePicture()).path;
      final lines = await widget.recognize(path);
      if (lines == null) {
        _manual();
        return;
      }
      final result = _progress.add(parseCardText(lines.join('\n')));
      if (result != null) {
        _finish(result);
      } else if (mounted) {
        setState(() {});
      }
    } on MissingPluginException {
      _manual();
    } catch (_) {
      // Снимок не получился или не распознался — берём следующий.
    } finally {
      // Снимок карты не должен оставаться на телефоне ни секунды дольше нужного.
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      _shooting = false;
    }
  }

  void _manual() {
    if (_done) return;
    _done = true;
    _stop();
    if (mounted) Navigator.of(context).pop();
  }

  void _finish(ScannedCard card) {
    if (_done) return;
    _done = true;
    HapticFeedback.mediumImpact();
    _stop();
    if (mounted) Navigator.of(context).pop(card);
  }

  Future<void> _toggleTorch() async {
    final camera = _camera;
    if (camera == null) return;
    final on = !_torch;
    try {
      await camera.setFlashMode(on ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _torch = on);
    } catch (_) {}
  }

  Widget _darkButton({required Widget child, required VoidCallback? onTap, String? tooltip, double? width}) {
    final button = SizedBox(
      height: 56,
      width: width,
      child: Material(
        color: _onDark,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Center(child: child)),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }

  Widget _frame() {
    final camera = _camera;
    final number = _progress.number;
    return AspectRatio(
      aspectRatio: 350 / 220,
      child: CustomPaint(
        foregroundPainter: _CornersPainter(),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(fit: StackFit.expand, children: [
              const ColoredBox(color: Color(0xFF2A3533)),
              if (camera != null && camera.value.isInitialized)
                FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(width: 100, height: 100 * camera.value.aspectRatio, child: CameraPreview(camera)),
                )
              else if (!_failed)
                const Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))),
              if (_failed)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(_t('noCamera'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 14, height: 20 / 14, color: Color(0xB8FFFFFF))),
                  ),
                ),
              if (number != null)
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 20,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(formatCardNumber(number),
                        maxLines: 1,
                        style: const TextStyle(
                            fontSize: 22, height: 28 / 22, fontWeight: FontWeight.w600, letterSpacing: 1.3,
                            color: Colors.white, fontFeatures: Q.tabular)),
                    const SizedBox(height: 8),
                    Text(_progress.expiry ?? '··/··',
                        style: const TextStyle(fontSize: 14, height: 20 / 14, color: Color(0xB8FFFFFF), fontFeatures: Q.tabular)),
                  ]),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final found = _progress.number != null;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent, systemNavigationBarColor: _dark),
      child: Scaffold(
        backgroundColor: _dark,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Q.gutter),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                height: 56,
                child: Row(children: [
                  Transform.translate(
                    offset: const Offset(-12, 0),
                    child: IconButton(
                      onPressed: _manual,
                      tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                      style: IconButton.styleFrom(fixedSize: const Size.square(44), minimumSize: const Size.square(44)),
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                    ),
                  ),
                  Expanded(child: Text(_t('title'), style: Q.appBar.copyWith(color: Colors.white))),
                ]),
              ),
              const SizedBox(height: 48),
              Center(
                child: Visibility(
                  visible: found,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: Container(
                    height: 32,
                    padding: const EdgeInsets.fromLTRB(8, 0, 12, 0),
                    decoration: BoxDecoration(color: _onDark, borderRadius: BorderRadius.circular(999)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.check_circle_rounded, size: 20, color: _found),
                      const SizedBox(width: 8),
                      Text(_t('found'),
                          style: const TextStyle(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w600, color: Colors.white)),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // На низком экране (альбомная ориентация, маленький телефон) рамка уменьшается, а не вылезает за край.
              Flexible(
                flex: 4,
                child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: _frame())),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_t('hint'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, height: 24 / 16, color: Color(0xCCFFFFFF))),
              ),
              const Spacer(),
              Row(children: [
                _darkButton(
                  width: 56,
                  tooltip: _t(_torch ? 'torchOff' : 'torchOn'),
                  onTap: _camera == null ? null : _toggleTorch,
                  child: Icon(_torch ? Icons.flashlight_off_rounded : Icons.flashlight_on_rounded, size: 24, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _darkButton(
                    onTap: _manual,
                    child: Text(_t('manual'),
                        style: const TextStyle(fontSize: 17, height: 24 / 17, fontWeight: FontWeight.w600, color: Colors.white)),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Уголки рамки: белая линия 4 pt со скруглёнными концами, радиус 16, по 32 pt на сторону угла.
class _CornersPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const r = 16.0, arm = 32.0, i = 2.0;
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(i, arm)
      ..lineTo(i, i + r)
      ..arcToPoint(Offset(i + r, i), radius: const Radius.circular(r))
      ..lineTo(arm, i)
      ..moveTo(w - arm, i)
      ..lineTo(w - i - r, i)
      ..arcToPoint(Offset(w - i, i + r), radius: const Radius.circular(r))
      ..lineTo(w - i, arm)
      ..moveTo(w - i, h - arm)
      ..lineTo(w - i, h - i - r)
      ..arcToPoint(Offset(w - i - r, h - i), radius: const Radius.circular(r))
      ..lineTo(w - arm, h - i)
      ..moveTo(arm, h - i)
      ..lineTo(i + r, h - i)
      ..arcToPoint(Offset(i, h - i - r), radius: const Radius.circular(r))
      ..lineTo(i, h - arm);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
