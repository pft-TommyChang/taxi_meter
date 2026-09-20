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

enum _LocationBlock { serviceDisabled, permissionDenied }

class _TaxiMeterPageState extends State<TaxiMeterPage> {
  final TaxiMeterController _meter = TaxiMeterController();
  final MeterSkin _skin = const FuguiMeterSkin();
  StreamSubscription<Position>? _positionSubscription;
  Timer? _ticker;
  String _locationStatus = '尚未開始定位';
  _TripSource? _tripSource;
  bool _simulationMoving = false;
  bool _isPaused = false;

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _startTrip() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await _offerSimulation(_LocationBlock.serviceDisabled);
      return;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      await _offerSimulation(_LocationBlock.permissionDenied);
      return;
    }

    final now = DateTime.now();
    setState(() {
      _meter.start(now);
      _tripSource = _TripSource.gps;
      _isPaused = false;
      _locationStatus = '正在取得高精度 GPS…';
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _subscribeToGps();
  }

  void _subscribeToGps() {
    _positionSubscription?.cancel();
    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: AppleSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 1,
            // Foreground-only: the meter runs while the app is open, so we do
            // not request background location updates.
            pauseLocationUpdatesAutomatically: false,
            showBackgroundLocationIndicator: false,
            allowBackgroundLocationUpdates: false,
          ),
        ).listen(
          _onPosition,
          onError: (_) {
            if (mounted) setState(() => _locationStatus = 'GPS 訊號暫時不可用');
          },
        );
  }

  // Pressing 計程計時 asks for GPS first; when the device has no usable GPS we
  // let the driver either open the relevant settings or fall back to demo mode.
  Future<void> _offerSimulation(_LocationBlock reason) async {
    if (!mounted) return;
    final message = reason == _LocationBlock.serviceDisabled
        ? '裝置的定位服務尚未開啟，無法使用 GPS 跳表。請開啟定位服務後再按一次「計程計時」，或先以模擬模式跳表。'
        : 'App 尚未取得定位權限，無法使用 GPS 跳表。請到設定開啟定位權限後再按一次「計程計時」，或先以模擬模式跳表。';
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('需要 GPS 權限'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'settings'),
            child: const Text('前往設定'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'demo'),
            child: const Text('模擬模式'),
          ),
        ],
      ),
    );
    switch (choice) {
      case 'settings':
        if (reason == _LocationBlock.serviceDisabled) {
          await Geolocator.openLocationSettings();
        } else {
          await Geolocator.openAppSettings();
        }
      case 'demo':
        _startSimulation();
    }
  }

  void _startSimulation() {
    final now = DateTime.now();
    setState(() {
      _meter.start(now);
      _tripSource = _TripSource.simulation;
      _simulationMoving = false;
      _isPaused = false;
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
    if (!_meter.isRunning || _isPaused) return;
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

  void _pauseTrip() {
    if (!_meter.isRunning || _isPaused) return;
    final now = DateTime.now();
    if (_tripSource == _TripSource.simulation) {
      _meter.advanceSimulation(now: now, moving: _simulationMoving);
    }
    _meter.pause(now);
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _isPaused = true;
      _locationStatus = '本趟暫停';
    });
  }

  void _resumeTrip() {
    if (!_meter.isRunning || !_isPaused) return;
    _meter.resume(DateTime.now());
    if (_tripSource == _TripSource.gps) {
      _subscribeToGps();
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    setState(() {
      _isPaused = false;
      _locationStatus = _tripSource == _TripSource.simulation
          ? (_simulationMoving ? '模擬模式 · 時速 80 公里' : '模擬模式 · 停車計時')
          : '正在取得高精度 GPS…';
    });
  }

  void _resetTrip() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _ticker?.cancel();
    _ticker = null;
    setState(() {
      _meter.reset();
      _tripSource = null;
      _simulationMoving = false;
      _isPaused = false;
      _locationStatus = '尚未開始定位';
    });
  }

  void _simulateMove() {
    if (_tripSource != _TripSource.simulation ||
        !_meter.isRunning ||
        _isPaused) {
      return;
    }
    setState(() {
      _simulationMoving = true;
      _locationStatus = '模擬模式 · 時速 80 公里';
    });
  }

  void _simulateIdle() {
    if (_tripSource != _TripSource.simulation ||
        !_meter.isRunning ||
        _isPaused) {
      return;
    }
    setState(() {
      _simulationMoving = false;
      _locationStatus = '模擬模式 · 停車計時';
    });
  }

  void _toggleNightSurcharge() {
    if (!_meter.isRunning) return;
    _meter.setNightSurcharge(!_meter.nightSurchargeActive);
    setState(() {});
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
      // The cabinet finish intentionally covers the full display, including
      // the unsafe system edges. Controls remain inside SafeArea below.
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xff32343b), Color(0xff08090d), Color(0xff17191f)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: _skin.build(
              context: context,
              reading: reading,
              fare: reading?.fare ?? 0,
              status: _locationStatus,
              isRunning: _meter.isRunning,
              isPaused: _isPaused,
              nightSurchargeActive: _meter.nightSurchargeActive,
              onStart: _startTrip,
              onSimulationStart: _startSimulation,
              onStop: _pauseTrip,
              onResume: _resumeTrip,
              onReset: _resetTrip,
              onNightSurcharge: _toggleNightSurcharge,
              onSettings: _openSettings,
              onSimulationMove:
                  _tripSource == _TripSource.simulation && !_isPaused
                  ? _simulateMove
                  : null,
              onSimulationIdle:
                  _tripSource == _TripSource.simulation && !_isPaused
                  ? _simulateIdle
                  : null,
              simulationMoving: _simulationMoving,
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
    required bool isPaused,
    required bool nightSurchargeActive,
    required VoidCallback onStart,
    required VoidCallback onSimulationStart,
    required VoidCallback onStop,
    required VoidCallback onResume,
    required VoidCallback onReset,
    required VoidCallback onNightSurcharge,
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
    required bool isPaused,
    required bool nightSurchargeActive,
    required VoidCallback onStart,
    required VoidCallback onSimulationStart,
    required VoidCallback onStop,
    required VoidCallback onResume,
    required VoidCallback onReset,
    required VoidCallback onNightSurcharge,
    required VoidCallback onSettings,
    required VoidCallback? onSimulationMove,
    required VoidCallback? onSimulationIdle,
    required bool simulationMoving,
  }) {
    final elapsed = reading?.elapsed ?? Duration.zero;
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
                    label: '空車',
                    active: isRunning,
                    onTap: isPaused ? onReset : (isRunning ? null : onStart),
                  ),
                  _Key(
                    label: '計程計時',
                    subtitle: status,
                    onTap: isPaused
                        ? onResume
                        : (isRunning ? null : onSimulationStart),
                  ),
                  _Key(
                    label: '停',
                    onTap: isRunning && !isPaused ? onStop : null,
                  ),
                  _Key(
                    label: '夜間加成',
                    subtitle: '23:00–06:00',
                    active: nightSurchargeActive,
                    onTap: isRunning ? onNightSurcharge : null,
                  ),
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
    required bool isPaused,
    required bool nightSurchargeActive,
    required VoidCallback onStart,
    required VoidCallback onSimulationStart,
    required VoidCallback onStop,
    required VoidCallback onResume,
    required VoidCallback onReset,
    required VoidCallback onNightSurcharge,
    required VoidCallback onSettings,
    required VoidCallback? onSimulationMove,
    required VoidCallback? onSimulationIdle,
    required bool simulationMoving,
  }) {
    // Physical taxi meters count 計時 only while the vehicle is below the
    // delayed-time threshold; elapsed trip time itself is not shown here.
    final waitingTime = reading?.waitingTime ?? Duration.zero;
    // Fixed "XX:XX" layout: always four digit slots plus the colon. Leading
    // zeros become blanks (each blank still occupies one LED slot), stopping at
    // the first non-zero digit; the final seconds digit is always kept.
    final rawClock =
        (waitingTime.inMinutes % 100).toString().padLeft(2, '0') +
        (waitingTime.inSeconds % 60).toString().padLeft(2, '0');
    final clockDigits = rawClock.split('');
    for (var i = 0; i < clockDigits.length - 1; i++) {
      if (clockDigits[i] != '0') break;
      clockDigits[i] = ' ';
    }
    final clock =
        '${clockDigits[0]}${clockDigits[1]}:${clockDigits[2]}${clockDigits[3]}';
    final distance = (reading?.distanceMeters ?? 0) / 1000;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Column(
        children: [
          _MeterStatusStrip(
            status: status,
            isRunning: isRunning,
            isPaused: isPaused,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 2, color: Color(0xff6a6d75)),
          ),
          Expanded(
            flex: 8,
            child: Row(
              children: [
                const Expanded(flex: 18, child: _FuguiBrand()),
                const SizedBox(width: 24),
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
                                label: '計時',
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
                                label: '行駛',
                                // Blank unused leading zeros; toStringAsFixed
                                // keeps the ones digit before the dot.
                                value: distance
                                    .toStringAsFixed(1)
                                    .padLeft(5, ' '),
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
                      const SizedBox(height: 18),
                      Expanded(
                        flex: 5,
                        child: _FareReadout(
                          // Blank before the trip starts; blank unused leading
                          // zeros once running (the ones digit is always kept).
                          value: reading == null
                              ? '    '
                              : fare.toString().padLeft(4, ' '),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 2, color: Color(0xff6a6d75)),
          ),
          Expanded(
            flex: 3,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final keyLabelSize = constraints.maxWidth * .040;
                return Row(
                  children: [
                    _LargeKey(
                      // This is a physical key cap, so its legend never changes
                      // with the meter state. The display above communicates state.
                      label: '空',
                      flex: 10,
                      labelSize: keyLabelSize,
                      // 空 is the on-duty state: selected (and therefore locked)
                      // while idle or metering; only pressable once stopped, to
                      // clear back to empty.
                      active: !isPaused,
                      onTap: isPaused ? onReset : null,
                    ),
                    const SizedBox(width: 8),
                    _LargeKey(
                      label: '計程計時',
                      flex: 24,
                      labelSize: keyLabelSize,
                      // Selected (and locked) while metering, from pressing
                      // 計程計時 until 停 is pressed. Starting asks for GPS
                      // first, then falls back to a demo prompt when GPS is
                      // unavailable; when stopped it resumes.
                      active: isRunning && !isPaused,
                      onTap: isPaused
                          ? onResume
                          : (isRunning ? null : onStart),
                    ),
                    const SizedBox(width: 8),
                    _LargeKey(
                      label: '停',
                      flex: 10,
                      labelSize: keyLabelSize,
                      active: isPaused,
                      onTap: isRunning && !isPaused ? onStop : null,
                    ),
                    const SizedBox(width: 8),
                    _LargeKey(
                      label: '夜間加成',
                      flex: 24,
                      labelSize: keyLabelSize,
                      active: nightSurchargeActive,
                      onTap: isRunning ? onNightSurcharge : null,
                    ),
                    const SizedBox(width: 8),
                    _LargeKey(
                      label: '設定',
                      flex: 15,
                      labelSize: keyLabelSize,
                      onTap: onSettings,
                    ),
                  ],
                );
              },
            ),
          ),
        ],
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
              'FK-98\nTAIPEI',
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

class _MeterStatusStrip extends StatelessWidget {
  const _MeterStatusStrip({
    required this.status,
    required this.isRunning,
    required this.isPaused,
  });

  final String status;
  final bool isRunning;
  final bool isPaused;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xff6a6d75), width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Text(
            isPaused ? '暫停' : (isRunning ? '計程中' : '空車'),
            style: const TextStyle(
              color: Color(0xffd4a44f),
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: SizedBox(
              height: 14,
              child: VerticalDivider(width: 2, color: Color(0xff6a6d75)),
            ),
          ),
          Expanded(
            child: Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xff999da6), fontSize: 12),
            ),
          ),
        ],
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
        Expanded(
          flex: 3,
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
        const SizedBox(width: 20),
        Expanded(
          flex: 6,
          child: _LedReadout(
            label: '',
            unit: '',
            value: value,
            onTap: onTap,
            active: active,
          ),
        ),
        const SizedBox(width: 20),
        Expanded(flex: 1, child: _OutsideUnit(unit)),
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
    // Right-align the whole row and reserve exactly four LED slots for the
    // price, so it no longer stretches into a wide, mostly-empty panel.
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              '車資',
              style: TextStyle(
                color: const Color(0xffb6a279),
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
                fontSize: h * 0.42,
              ),
            ),
            SizedBox(width: h * 0.14),
            SizedBox(
              height: h,
              width: h * 2.3,
              child: _LedReadout(label: '', unit: '', value: value, main: true),
            ),
            SizedBox(width: h * 0.12),
            Text(
              '元',
              style: TextStyle(
                color: const Color(0xffd2b16d),
                fontWeight: FontWeight.w900,
                fontSize: h * 0.36,
              ),
            ),
          ],
        );
      },
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

class _LargeKey extends StatefulWidget {
  const _LargeKey({
    required this.label,
    required this.flex,
    required this.labelSize,
    this.active = false,
    this.onTap,
  });

  final String label;
  final int flex;
  final double labelSize;
  final bool active;
  final VoidCallback? onTap;

  @override
  State<_LargeKey> createState() => _LargeKeyState();
}

class _LargeKeyState extends State<_LargeKey> {
  bool _isPressed = false;

  void _setPressed(bool value) {
    if (mounted) setState(() => _isPressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: widget.flex,
      child: Padding(
        // Separators are placed by the parent row, so its edge keys are flush.
        padding: EdgeInsets.zero,
        child: Semantics(
          button: true,
          enabled: widget.onTap != null,
          label: widget.label,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onTapDown: widget.onTap == null ? null : (_) => _setPressed(true),
            onTapUp: widget.onTap == null ? null : (_) => _setPressed(false),
            onTapCancel: widget.onTap == null ? null : () => _setPressed(false),
            child: AnimatedScale(
              scale: _isPressed ? .94 : 1,
              duration: const Duration(milliseconds: 75),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 75),
                decoration: BoxDecoration(
                  color: widget.active
                      ? const Color(0xffd6ae58)
                      : const Color(0xffe5e0cf),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _isPressed
                        ? const Color(0xff6a6251)
                        : const Color(0xfff8f3df),
                    width: _isPressed ? 3 : 2,
                  ),
                  boxShadow: _isPressed
                      ? const []
                      : const [
                          BoxShadow(
                            color: Color(0x88000000),
                            offset: Offset(0, 5),
                            blurRadius: 2,
                          ),
                        ],
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) => Center(
                    // A shared, deliberately modest size keeps engraved key
                    // legends visually uniform instead of scaling per key.
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        color: const Color(0xff252831),
                        fontSize: widget.labelSize,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
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
