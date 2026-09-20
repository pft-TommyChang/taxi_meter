import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'taxi_meter_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const TaxiMeterApp());
}

class TaxiMeterApp extends StatelessWidget {
  const TaxiMeterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '台北跳表',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffbd1111)),
        useMaterial3: true,
      ),
      home: const TaxiMeterPage(),
    );
  }
}

class TaxiMeterPage extends StatefulWidget {
  const TaxiMeterPage({super.key});

  @override
  State<TaxiMeterPage> createState() => _TaxiMeterPageState();
}

enum _TripSource { gps, simulation }

class _TaxiMeterPageState extends State<TaxiMeterPage> {
  final TaxiMeterController _meter = TaxiMeterController();
  final MeterSkin _skin = const FuguiMeterSkin();
  StreamSubscription<Position>? _positionSubscription;
  Timer? _ticker;
  String _locationStatus = '尚未開始定位';
  _TripSource? _tripSource;
  bool _simulationMoving = false;

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _startTrip() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await _offerSimulation();
      return;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      await _offerSimulation();
      return;
    }

    final now = DateTime.now();
    setState(() {
      _meter.start(now);
      _tripSource = _TripSource.gps;
      _locationStatus = '正在取得高精度 GPS…';
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: AppleSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 1,
            pauseLocationUpdatesAutomatically: false,
            showBackgroundLocationIndicator: true,
            allowBackgroundLocationUpdates: true,
          ),
        ).listen(
          _onPosition,
          onError: (_) {
            if (mounted) setState(() => _locationStatus = 'GPS 訊號暫時不可用');
          },
        );
  }

  Future<void> _offerSimulation() async {
    if (!mounted) return;
    final shouldSimulate = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('以模擬模式開始？'),
        content: const Text(
          '目前沒有可用的 GPS。模擬模式可照常跳表：點「行駛公里」會以時速 80 公里前進；點「計程時間」會停止前進並累計延滯時間。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('模擬開始'),
          ),
        ],
      ),
    );
    if (shouldSimulate == true) _startSimulation();
  }

  void _startSimulation() {
    final now = DateTime.now();
    setState(() {
      _meter.start(now);
      _tripSource = _TripSource.simulation;
      _simulationMoving = false;
      _locationStatus = '模擬模式 · 停車計時';
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _onPosition(Position position) {
    final before = _meter.reading?.fare ?? 0;
    _meter.addGpsSample(
      timestamp: position.timestamp,
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyMeters: position.accuracy,
      speedMetersPerSecond: position.speed,
      distanceBetween: Geolocator.distanceBetween,
    );
    final reading = _meter.reading;
    if (reading == null || !mounted) return;
    if (reading.fare > before) _beep();
    setState(() {
      _locationStatus = reading.accuracyMeters == null
          ? '等待可用 GPS'
          : 'GPS 精度 ±${reading.accuracyMeters!.round()} m';
    });
  }

  void _tick() {
    if (!_meter.isRunning) return;
    final before = _meter.reading?.fare ?? 0;
    if (_tripSource == _TripSource.simulation) {
      _meter.advanceSimulation(now: DateTime.now(), moving: _simulationMoving);
    } else {
      _meter.tick(DateTime.now());
    }
    final after = _meter.reading?.fare ?? 0;
    if (after > before) _beep();
    if (mounted) setState(() {});
  }

  void _beep() {
    HapticFeedback.selectionClick();
    SystemSound.play(SystemSoundType.click);
  }

  void _stopTrip() {
    final now = DateTime.now();
    if (_tripSource == _TripSource.simulation) {
      _meter.advanceSimulation(now: now, moving: _simulationMoving);
    } else {
      _meter.stop(now);
    }
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _tripSource = null;
      _simulationMoving = false;
      _locationStatus = '本趟已結束';
    });
  }

  void _resetTrip() {
    _stopTrip();
    setState(() {
      _meter.reset();
      _tripSource = null;
      _simulationMoving = false;
      _locationStatus = '尚未開始定位';
    });
  }

  void _simulateMove() {
    if (_tripSource != _TripSource.simulation || !_meter.isRunning) return;
    setState(() {
      _simulationMoving = true;
      _locationStatus = '模擬模式 · 時速 80 公里';
    });
  }

  void _simulateIdle() {
    if (_tripSource != _TripSource.simulation || !_meter.isRunning) return;
    setState(() {
      _simulationMoving = false;
      _locationStatus = '模擬模式 · 停車計時';
    });
  }

  void _openSettings() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('設定'),
        content: const Text('目前面板：富貴 FK-98\n計費方式：大臺北\nGPS：高精度、背景持續定位'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _resetTrip();
            },
            child: const Text('重設本趟'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reading = _meter.reading;
    return Scaffold(
      backgroundColor: const Color(0xff08090b),
      body: SafeArea(
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: 2500,
              height: 1000,
              child: _skin.build(
                context: context,
                reading: reading,
                fare: reading?.fare ?? 0,
                status: _locationStatus,
                isRunning: _meter.isRunning,
                onStart: _startTrip,
                onSimulationStart: _startSimulation,
                onStop: _stopTrip,
                onSettings: _openSettings,
                onSimulationMove: _tripSource == _TripSource.simulation
                    ? _simulateMove
                    : null,
                onSimulationIdle: _tripSource == _TripSource.simulation
                    ? _simulateIdle
                    : null,
                simulationMoving: _simulationMoving,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

abstract class MeterSkin {
  const MeterSkin();

  Widget build({
    required BuildContext context,
    required TripReading? reading,
    required int fare,
    required String status,
    required bool isRunning,
    required VoidCallback onStart,
    required VoidCallback onSimulationStart,
    required VoidCallback onStop,
    required VoidCallback onSettings,
    required VoidCallback? onSimulationMove,
    required VoidCallback? onSimulationIdle,
    required bool simulationMoving,
  });
}

/// Retained only as a layout-development reference; the production skin below
/// is the active implementation.
// ignore: unused_element
class _LegacyFuguiMeterSkin extends MeterSkin {
  const _LegacyFuguiMeterSkin();

  @override
  Widget build({
    required BuildContext context,
    required TripReading? reading,
    required int fare,
    required String status,
    required bool isRunning,
    required VoidCallback onStart,
    required VoidCallback onSimulationStart,
    required VoidCallback onStop,
    required VoidCallback onSettings,
    required VoidCallback? onSimulationMove,
    required VoidCallback? onSimulationIdle,
    required bool simulationMoving,
  }) {
    final onReset = onSettings;
    final elapsed = reading == null
        ? Duration.zero
        : DateTime.now().difference(reading.startedAt);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xff30323a), Color(0xff08090d), Color(0xff17191f)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        border: Border.all(color: const Color(0xff676b75), width: 2),
        boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 16)],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 13, 28, 11),
        child: Column(
          children: [
            Expanded(
              flex: 8,
              child: Row(
                children: [
                  const Expanded(flex: 2, child: _BrandPlate()),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 4,
                    child: Column(
                      children: [
                        Expanded(
                          child: _Readout(
                            label: '計程時間',
                            value: _clock(elapsed),
                            compact: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _Readout(
                            label: '行駛公里',
                            value: _distance(reading?.distanceMeters ?? 0),
                            compact: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 5,
                    child: _Readout(
                      label: '應收金額　元',
                      value: fare.toString(),
                      main: true,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              flex: 2,
              child: Row(
                children: [
                  _Key(
                    label: isRunning ? '計程中' : '空車',
                    active: isRunning,
                    onTap: isRunning ? null : onStart,
                  ),
                  _Key(
                    label: '計程計時',
                    subtitle: status,
                    onTap: isRunning ? onStop : onSimulationStart,
                  ),
                  _Key(label: '停', onTap: isRunning ? onStop : null),
                  _Key(label: '夜間加成', subtitle: '23:00–06:00', onTap: null),
                  _Key(label: '列印', subtitle: '重設', onTap: onReset),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _clock(Duration value) =>
      '${value.inHours.toString().padLeft(2, '0')}:${(value.inMinutes % 60).toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  static String _distance(double meters) => (meters / 1000).toStringAsFixed(2);
}

class _BrandPlate extends StatelessWidget {
  const _BrandPlate();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: Color(0xff575b65))),
      ),
      child: Padding(
        padding: EdgeInsets.only(right: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '富 貴',
              style: TextStyle(
                color: Color(0xffd6a54d),
                fontWeight: FontWeight.w900,
                fontSize: 29,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'FU GUI  TAXIMETER\nTAIPEI · GPS MODE',
              style: TextStyle(
                color: Color(0xffa4a8b1),
                fontSize: 8,
                letterSpacing: 1.2,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Readout extends StatelessWidget {
  const _Readout({
    required this.label,
    required this.value,
    this.main = false,
    this.compact = false,
  });

  final String label;
  final String value;
  final bool main;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xff5d0408),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffc76734), width: 2),
        boxShadow: const [
          BoxShadow(color: Color(0x99f52020), blurRadius: 11, spreadRadius: 1),
        ],
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Opacity(
              opacity: .15,
              child: Text(
                '888888',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: main ? 74 : 30,
                  color: Colors.red,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xffffb29a),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        value,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          color: const Color(0xffff251c),
                          fontWeight: FontWeight.w900,
                          fontSize: main ? 74 : (compact ? 31 : 38),
                          letterSpacing: main ? 3 : 0,
                          shadows: const [
                            Shadow(color: Color(0xffff6050), blurRadius: 12),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    required this.label,
    this.subtitle,
    this.active = false,
    this.onTap,
  });

  final String label;
  final String? subtitle;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Material(
          color: active ? const Color(0xffd6ae58) : const Color(0xffe5e0cf),
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            onTap: onTap ?? () {},
            splashColor: const Color(0xffb87816).withValues(alpha: .4),
            highlightColor: const Color(0xff8f5c12).withValues(alpha: .2),
            borderRadius: BorderRadius.circular(7),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xff252831),
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xff555861),
                          fontSize: 7,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The production 富貴-inspired layout.  The older experiment above is kept out
/// of the active skin while this layout deliberately follows the physical
/// FK-98's wide display hierarchy.
class FuguiMeterSkin extends MeterSkin {
  const FuguiMeterSkin();

  @override
  Widget build({
    required BuildContext context,
    required TripReading? reading,
    required int fare,
    required String status,
    required bool isRunning,
    required VoidCallback onStart,
    required VoidCallback onSimulationStart,
    required VoidCallback onStop,
    required VoidCallback onSettings,
    required VoidCallback? onSimulationMove,
    required VoidCallback? onSimulationIdle,
    required bool simulationMoving,
  }) {
    final elapsed = reading == null
        ? Duration.zero
        : DateTime.now().difference(reading.startedAt);
    final clock =
        '${(elapsed.inMinutes % 100).toString().padLeft(2, '0')}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    final distance = (reading?.distanceMeters ?? 0) / 1000;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xff32343b), Color(0xff08090d), Color(0xff17191f)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        border: Border.all(color: const Color(0xff71747d), width: 2),
        boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 16)],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(25, 10, 25, 9),
        child: Column(
          children: [
            Expanded(
              flex: 7,
              child: Row(
                children: [
                  const Expanded(flex: 18, child: _FuguiBrand()),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 82,
                    child: Column(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Row(
                            children: [
                              Expanded(
                                flex: 5,
                                child: _TopMetric(
                                  label: '計程時間',
                                  value: clock,
                                  unit: '秒',
                                  onTap: onSimulationIdle,
                                  active:
                                      onSimulationIdle != null &&
                                      !simulationMoving,
                                ),
                              ),
                              Container(
                                width: 3,
                                height: 150,
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 28,
                                ),
                                color: const Color(0xff686b72),
                              ),
                              Expanded(
                                flex: 5,
                                child: _TopMetric(
                                  label: '行駛公里',
                                  value: distance
                                      .toStringAsFixed(1)
                                      .padLeft(5, '0'),
                                  unit: '公里',
                                  onTap: onSimulationMove,
                                  active:
                                      onSimulationMove != null &&
                                      simulationMoving,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          flex: 5,
                          child: Row(
                            children: [
                              Expanded(
                                flex: 19,
                                child: _FareStatus(
                                  status: status,
                                  isRunning: isRunning,
                                ),
                              ),
                              const SizedBox(width: 9),
                              Expanded(
                                flex: 81,
                                child: _FareReadout(
                                  value: reading == null
                                      ? '----'
                                      : fare.toString().padLeft(4, '0'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 7),
              child: Divider(height: 2, color: Color(0xff6a6d75)),
            ),
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  _LargeKey(
                    label: isRunning ? '計程中' : '空',
                    flex: 12,
                    active: isRunning,
                    onTap: isRunning ? null : onStart,
                  ),
                  _LargeKey(
                    label: '計程計時',
                    flex: 19,
                    active: onSimulationIdle != null && !simulationMoving,
                    onTap: isRunning ? onStop : onSimulationStart,
                  ),
                  _LargeKey(
                    label: '停',
                    flex: 11,
                    onTap: isRunning ? onStop : null,
                  ),
                  _LargeKey(label: '夜間加成', flex: 21),
                  _LargeKey(label: '設定', flex: 12, onTap: onSettings),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FuguiBrand extends StatelessWidget {
  const _FuguiBrand();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: Color(0xff575b65))),
      ),
      child: Padding(
        padding: EdgeInsets.only(right: 7),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '富貴',
              style: TextStyle(
                color: Color(0xffd9a94e),
                fontWeight: FontWeight.w900,
                fontSize: 40,
              ),
            ),
            SizedBox(height: 4),
            Text(
              'FK-98\nTAXIMETER\nTAIPEI',
              style: TextStyle(
                color: Color(0xffa4a8b1),
                fontSize: 16,
                letterSpacing: 1.1,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FareStatus extends StatelessWidget {
  const _FareStatus({required this.status, required this.isRunning});

  final String status;
  final bool isRunning;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: Color(0xff575b65))),
      ),
      child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isRunning ? '計程中' : '空 車',
              style: const TextStyle(
                color: Color(0xffd4a44f),
                fontSize: 23,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xff999da6),
                fontSize: 16,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopMetric extends StatelessWidget {
  const _TopMetric({
    required this.label,
    required this.unit,
    required this.value,
    this.onTap,
    this.active = false,
  });

  final String label;
  final String unit;
  final String value;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 300,
          child: FittedBox(
            fit: BoxFit.contain,
            child: Text(
              label,
              style: TextStyle(
                color: active
                    ? const Color(0xffffc85b)
                    : const Color(0xffb6a279),
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
                fontSize: 100,
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _LedReadout(
            label: '',
            unit: '',
            value: value,
            onTap: onTap,
            active: active,
          ),
        ),
        const SizedBox(width: 16),
        SizedBox(width: 92, child: _OutsideUnit(unit)),
      ],
    );
  }
}

class _LedReadout extends StatelessWidget {
  const _LedReadout({
    required this.label,
    required this.unit,
    required this.value,
    this.main = false,
    this.onTap,
    this.active = false,
  });

  final String label;
  final String unit;
  final String value;
  final bool main;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xff5d0408),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: active ? const Color(0xffffcb61) : const Color(0xffc76734),
            width: active ? 3 : 2,
          ),
          boxShadow: const [BoxShadow(color: Color(0x66f52020), blurRadius: 9)],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            children: [
              if (label.isNotEmpty || unit.isNotEmpty) ...[
                Row(
                  children: [
                    if (label.isNotEmpty)
                      Text(
                        label,
                        style: const TextStyle(
                          color: Color(0xffffb29a),
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    const Spacer(),
                    if (unit.isNotEmpty)
                      Text(
                        unit,
                        style: const TextStyle(
                          color: Color(0xffffb29a),
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
              ],
              Expanded(
                child: _LedDigits(value: value, main: main),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutsideUnit extends StatelessWidget {
  const _OutsideUnit(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: 100,
        height: 200,
        child: Center(
          child: value.length == 1
              ? Text(
                  value,
                  style: const TextStyle(
                    color: Color(0xffd2b16d),
                    fontSize: 100,
                    fontWeight: FontWeight.w900,
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: value
                      .split('')
                      .map(
                        (character) => Text(
                          character,
                          style: const TextStyle(
                            color: Color(0xffd2b16d),
                            fontSize: 90,
                            fontWeight: FontWeight.w900,
                            height: .85,
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
      ),
    );
  }
}

class _FareReadout extends StatelessWidget {
  const _FareReadout({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _LedReadout(label: '應收金額', unit: '', value: value, main: true),
        ),
        const SizedBox(width: 16),
        const SizedBox(width: 100, child: _OutsideUnit('元')),
      ],
    );
  }
}

class _LedDigits extends StatelessWidget {
  const _LedDigits({required this.value, required this.main});

  final String value;
  final bool main;

  @override
  Widget build(BuildContext context) {
    final width = value
        .split('')
        .fold<double>(
          0,
          (sum, char) => sum + (char == ':' || char == '.' ? 23 : 60),
        );
    return FittedBox(
      fit: BoxFit.contain,
      child: CustomPaint(
        size: Size(width, 100),
        painter: _SevenSegmentPainter(value, brightness: main ? 1 : .9),
      ),
    );
  }
}

class _SevenSegmentPainter extends CustomPainter {
  _SevenSegmentPainter(this.value, {required this.brightness});

  final String value;
  final double brightness;

  static const segments = <String, Set<int>>{
    '0': {0, 1, 2, 3, 4, 5},
    '1': {1, 2},
    '2': {0, 1, 6, 4, 3},
    '3': {0, 1, 6, 2, 3},
    '4': {5, 6, 1, 2},
    '5': {0, 5, 6, 2, 3},
    '6': {0, 5, 6, 4, 2, 3},
    '7': {0, 1, 2},
    '8': {0, 1, 2, 3, 4, 5, 6},
    '9': {0, 1, 2, 3, 5, 6},
    '-': {6},
  };

  @override
  void paint(Canvas canvas, Size size) {
    var x = 0.0;
    for (final char in value.split('')) {
      if (char == ':' || char == '.') {
        final paint = Paint()
          ..color = const Color(0xffff2c20).withValues(alpha: brightness);
        if (char == ':') {
          canvas.drawCircle(Offset(x + 10, 35), 5, paint);
          canvas.drawCircle(Offset(x + 10, 72), 5, paint);
        } else {
          canvas.drawCircle(Offset(x + 8, 90), 6, paint);
        }
        x += 23;
        continue;
      }
      for (final segment in segments[char] ?? const <int>{}) {
        final path = _path(x, segment);
        canvas.drawPath(
          path,
          Paint()
            ..color = const Color(
              0xffff3a2d,
            ).withValues(alpha: .45 * brightness)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
        );
        canvas.drawPath(
          path,
          Paint()
            ..color = const Color(0xffff281d).withValues(alpha: brightness),
        );
      }
      x += 60;
    }
  }

  Path _path(double x, int segment) {
    Path horizontal(double y) => Path()
      ..moveTo(x + 8, y)
      ..lineTo(x + 44, y)
      ..lineTo(x + 51, y + 5.5)
      ..lineTo(x + 44, y + 11)
      ..lineTo(x + 8, y + 11)
      ..lineTo(x + 1, y + 5.5)
      ..close();
    Path vertical(double y, bool right) {
      final left = x + (right ? 43 : 1);
      return Path()
        ..moveTo(left + 6, y + 3)
        ..lineTo(left + 12, y + 10)
        ..lineTo(left + 12, y + 39)
        ..lineTo(left + 6, y + 45)
        ..lineTo(left, y + 39)
        ..lineTo(left, y + 10)
        ..close();
    }

    return switch (segment) {
      0 => horizontal(0),
      1 => vertical(7, true),
      2 => vertical(51, true),
      3 => horizontal(89),
      4 => vertical(51, false),
      5 => vertical(7, false),
      _ => horizontal(44),
    };
  }

  @override
  bool shouldRepaint(covariant _SevenSegmentPainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.brightness != brightness;
}

class _LargeKey extends StatelessWidget {
  const _LargeKey({
    required this.label,
    required this.flex,
    this.active = false,
    this.onTap,
  });

  final String label;
  final int flex;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Material(
          color: active ? const Color(0xffd6ae58) : const Color(0xffe5e0cf),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: onTap ?? () {},
            splashColor: const Color(0xffb87816).withValues(alpha: .4),
            highlightColor: const Color(0xff8f5c12).withValues(alpha: .2),
            borderRadius: BorderRadius.circular(14),
            child: Center(
              child: FittedBox(
                fit: BoxFit.contain,
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xff252831),
                    fontSize: 38,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
