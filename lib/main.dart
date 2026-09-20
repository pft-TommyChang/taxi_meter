import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'taxi_meter_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
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

  void _printReceipt() {
    final reading = _meter.reading;
    if (reading == null) return;
    final receipt = _buildReceiptText(reading);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('本趟明細'),
        content: SingleChildScrollView(
          child: Text(
            receipt,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              height: 1.6,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('關閉'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: receipt));
              if (!context.mounted) return;
              Navigator.pop(dialogContext);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已複製本趟明細到剪貼簿')),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('複製'),
          ),
        ],
      ),
    );
  }

  String _buildReceiptText(TripReading reading) {
    String two(int n) => n.toString().padLeft(2, '0');
    final s = reading.startedAt;
    final started =
        '${s.year}-${two(s.month)}-${two(s.day)} ${two(s.hour)}:${two(s.minute)}';
    final wait = reading.waitingTime;
    final waitStr =
        '${two(wait.inMinutes % 60)}:${two(wait.inSeconds % 60)}';
    final km = (reading.distanceMeters / 1000).toStringAsFixed(2);
    final night = _meter.nightSurchargeActive ? '是' : '否';
    return [
      '台北跳表  富貴 FK-98',
      '營業區：北北基',
      '--------------------',
      '上車時間：$started',
      '行駛里程：$km 公里',
      '延滯計時：$waitStr',
      '夜間加成：$night',
      '--------------------',
      '應收金額：NT\$${reading.fare}',
    ].join('\n');
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
              onPrint: _printReceipt,
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
    required VoidCallback onPrint,
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
    required VoidCallback onPrint,
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
    required VoidCallback onPrint,
    required VoidCallback? onSimulationMove,
    required VoidCallback? onSimulationIdle,
    required bool simulationMoving,
  }) {
    // Portrait uses a dedicated top-to-bottom layout; landscape keeps the
    // original wide FK-98 layout below completely unchanged.
    if (MediaQuery.orientationOf(context) == Orientation.portrait) {
      return _buildPortrait(
        context: context,
        reading: reading,
        fare: fare,
        status: status,
        isRunning: isRunning,
        isPaused: isPaused,
        nightSurchargeActive: nightSurchargeActive,
        onStart: onStart,
        onSimulationStart: onSimulationStart,
        onStop: onStop,
        onResume: onResume,
        onReset: onReset,
        onNightSurcharge: onNightSurcharge,
        onSettings: onSettings,
        onPrint: onPrint,
        onSimulationMove: onSimulationMove,
        onSimulationIdle: onSimulationIdle,
        simulationMoving: simulationMoving,
      );
    }
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
            onSettings: onSettings,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 2, color: Color(0xff6a6d75)),
          ),
          Expanded(
            flex: 8,
            child: Row(
              children: [
                Expanded(flex: 18, child: _FuguiBrand(active: isRunning && !isPaused)),
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
                                unit: '秒　',
                                onTap: onSimulationIdle,
                                active:
                                    onSimulationIdle != null &&
                                    !simulationMoving,
                              ),
                            ),
                            Container(
                              width: 1,
                              height: 150,
                              margin: const EdgeInsets.symmetric(
                                horizontal: 28,
                              ),
                              color: const Color(0xff6a6d75),
                            ),
                            Expanded(
                              flex: 5,
                              child: _TopMetric(
                                label: '計程',
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
                          // Always show the fare: 0 before/after a trip, and
                          // unused leading zeros render as faint ghost slots.
                          value: fare.toString().padLeft(4, ' '),
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
            child: Padding(
              // Inset the key row so the buttons read smaller with more
              // breathing room around them.
              padding: const EdgeInsets.fromLTRB(48, 8, 48, 10),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Size the legend by BOTH axes so tall CJK glyphs are never
                  // clipped vertically when the key is short.
                  final byWidth = constraints.maxWidth * .042;
                  final byHeight = constraints.maxHeight * .42;
                  final keyLabelSize =
                      byWidth < byHeight ? byWidth : byHeight;
                  return Row(
                    children: [
                      _LargeKey(
                        label: '空',
                        flex: 10,
                        labelSize: keyLabelSize,
                        active: !isPaused,
                        onTap: isPaused ? onReset : null,
                      ),
                      const SizedBox(width: 8),
                      _LargeKey(
                        label: '計程計時',
                        flex: 24,
                        labelSize: keyLabelSize,
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
                        onTap: onNightSurcharge,
                      ),
                      const SizedBox(width: 8),
                      _LargeKey(
                        label: '列印',
                        flex: 15,
                        labelSize: keyLabelSize,
                        onTap: isPaused ? onPrint : null,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Portrait layout: one readout per row, top to bottom. Reuses the same LED
  /// readout and key widgets as landscape; each _LedReadout is width-flexible
  /// (FittedBox), so nothing overflows in the tall/narrow aspect ratio.
  Widget _buildPortrait({
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
    required VoidCallback onPrint,
    required VoidCallback? onSimulationMove,
    required VoidCallback? onSimulationIdle,
    required bool simulationMoving,
  }) {
    final waitingTime = reading?.waitingTime ?? Duration.zero;
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

    const divider = Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Divider(height: 2, color: Color(0xff6a6d75)),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MeterStatusStrip(
            status: status,
            isRunning: isRunning,
            isPaused: isPaused,
            onSettings: onSettings,
          ),
          divider,
          _PortraitBrand(active: isRunning && !isPaused),
          divider,
          Expanded(
            flex: 5,
            child: _LedReadout(
              label: '計時',
              unit: '秒',
              value: clock,
              onTap: onSimulationIdle,
              active: onSimulationIdle != null && !simulationMoving,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            flex: 5,
            child: _LedReadout(
              label: '計程',
              unit: '公里',
              value: distance.toStringAsFixed(1).padLeft(5, ' '),
              onTap: onSimulationMove,
              active: onSimulationMove != null && simulationMoving,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            flex: 7,
            child: _LedReadout(
              label: '車資',
              unit: '元',
              value: fare.toString().padLeft(4, ' '),
              main: true,
            ),
          ),
          divider,
          Expanded(
            flex: 8,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final keyLabelSize = constraints.maxWidth * .06;
                const gap = SizedBox(width: 8);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Row 1: trip-flow keys.
                    Expanded(
                      child: Row(
                        children: [
                          _LargeKey(
                            label: '空',
                            flex: 10,
                            labelSize: keyLabelSize,
                            active: !isPaused,
                            onTap: isPaused ? onReset : null,
                          ),
                          gap,
                          _LargeKey(
                            label: '計程計時',
                            flex: 24,
                            labelSize: keyLabelSize,
                            active: isRunning && !isPaused,
                            onTap: isPaused
                                ? onResume
                                : (isRunning ? null : onStart),
                          ),
                          gap,
                          _LargeKey(
                            label: '停',
                            flex: 10,
                            labelSize: keyLabelSize,
                            active: isPaused,
                            onTap: isRunning && !isPaused ? onStop : null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Row 2: options.
                    Expanded(
                      child: Row(
                        children: [
                          _LargeKey(
                            label: '夜間加成',
                            flex: 24,
                            labelSize: keyLabelSize,
                            active: nightSurchargeActive,
                            onTap: onNightSurcharge,
                          ),
                          gap,
                          _LargeKey(
                            label: '列印',
                            flex: 15,
                            labelSize: keyLabelSize,
                            onTap: isPaused ? onPrint : null,
                          ),
                        ],
                      ),
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

/// Compact brand header used only by the portrait layout.
class _PortraitBrand extends StatelessWidget {
  const _PortraitBrand({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text(
          '富貴',
          style: TextStyle(
            color: Color(0xffd9a94e),
            fontWeight: FontWeight.w900,
            fontSize: 30,
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          'FK-98',
          style: TextStyle(
            color: Color(0xffa4a8b1),
            fontSize: 14,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(width: 18),
        const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '營業區:',
              style: TextStyle(
                color: Color(0xffa4a8b1),
                fontWeight: FontWeight.w900,
                fontSize: 11,
              ),
            ),
            Text(
              '北北基',
              style: TextStyle(
                color: Color(0xffffe23d),
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
                fontSize: 13,
              ),
            ),
          ],
        ),
        const Spacer(),
        _MeteringIndicator(active: active, fontSize: 15),
      ],
    );
  }
}

class _FuguiBrand extends StatelessWidget {
  const _FuguiBrand({required this.active});

  /// True while the meter is actively running; turns 計程中 green.
  final bool active;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: Color(0xff575b65))),
      ),
      child: Padding(
        padding: const EdgeInsets.only(right: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '富貴',
              style: TextStyle(
                color: Color(0xffd9a94e),
                fontWeight: FontWeight.w900,
                fontSize: 40,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'FK-98',
              style: TextStyle(
                color: Color(0xffa4a8b1),
                fontSize: 16,
                letterSpacing: 1.1,
                height: 1.4,
              ),
            ),
            const Spacer(),
            _MeteringIndicator(active: active, fontSize: 16),
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
    required this.onSettings,
  });

  final String status;
  final bool isRunning;
  final bool isPaused;
  final VoidCallback onSettings;

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
          const SizedBox(width: 8),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onSettings,
            child: const Icon(
              Icons.settings,
              color: Color(0xffb6a279),
              size: 20,
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
        const SizedBox(width: 16),
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
        const SizedBox(width: 16),
        Expanded(flex: 3, child: _OutsideUnit(unit)),
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
    // Single line for any unit; FittedBox scales it to the slot height, so 公里
    // (two chars) renders at the same character size as 秒.
    return FittedBox(
      fit: BoxFit.contain,
      child: Text(
        value,
        maxLines: 1,
        style: const TextStyle(
          color: Color(0xffd2b16d),
          fontSize: 100,
          fontWeight: FontWeight.w900,
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
    // 北市費率 sits in the empty space on the left; a Spacer keeps 車資 /
    // price / 元 aligned to the right. Four LED slots are reserved for the price
    // so it never stretches into a wide, mostly-empty panel.
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '營業區:',
                  style: TextStyle(
                    color: Color(0xffa4a8b1), // grey
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                    fontSize: 16,
                  ),
                ),
                Text(
                  '北北基',
                  style: TextStyle(
                    color: Color(0xffffe23d), // bright yellow
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text(
              '車資',
              style: TextStyle(
                color: const Color(0xffb6a279),
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
                fontSize: h * 0.36,
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

/// A bordered "計程中" legend: light grey when idle, solid green while metering.
class _MeteringIndicator extends StatelessWidget {
  const _MeteringIndicator({required this.active, required this.fontSize});

  final bool active;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xff45e784) : const Color(0xff8b8f98);
    final f = fontSize;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: f * 0.55, vertical: f * 0.3),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: f * 0.1),
        borderRadius: BorderRadius.circular(f * 0.4),
      ),
      child: Text(
        '計程中',
        style: TextStyle(
          color: color,
          fontSize: f,
          fontWeight: FontWeight.w900,
          letterSpacing: 1,
        ),
      ),
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

  // Segment indices: 0=top, 1=top-right, 2=bottom-right, 3=bottom,
  // 4=bottom-left, 5=top-left, 6=middle.
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

  // Digit geometry inside a [cell] x 100 box. Horizontal bars span [x0, x0 + w]
  // and vertical bars sit at x0 + t/2 and x0 + w - t/2, all sharing the same
  // y0 / h / t, so every corner lines up and the 45-degree notches between
  // neighbouring segments stay perfectly even.
  static const double cell = 60;
  static const double x0 = 8;
  static const double w = 44;
  static const double y0 = 5;
  static const double h = 90;
  static const double t = 11; // segment thickness
  static const double gap = 2.6; // notch between neighbouring segments

  static const Color _onColor = Color(0xffff2a1d);
  static const Color _glowColor = Color(0xffff5a48);
  static const Color _offColor = Color(0xffff6a58);

  @override
  void paint(Canvas canvas, Size size) {
    var x = 0.0;
    for (final char in value.split('')) {
      if (char == ':' || char == '.') {
        _drawPunctuation(canvas, x, char);
        x += 23;
        continue;
      }
      // Every slot shows all seven segments: lit ones bright, the rest as a
      // faint ghost -- including blank/space slots, which become a full ghost 8.
      final active = segments[char] ?? const <int>{};
      for (var seg = 0; seg < 7; seg++) {
        _drawSegment(canvas, x, seg, active.contains(seg));
      }
      x += cell;
    }
  }

  void _drawSegment(Canvas canvas, double x, int seg, bool on) {
    final path = _path(x, seg);
    if (on) {
      // Soft bloom underneath, then the crisp lit segment on top.
      canvas.drawPath(
        path,
        Paint()
          ..color = _glowColor.withValues(alpha: .5 * brightness)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawPath(
        path,
        Paint()..color = _onColor.withValues(alpha: brightness),
      );
    } else {
      // Unlit segment: a faint ghost so the full digit outline is always
      // visible, like a real red LED module under light.
      canvas.drawPath(
        path,
        Paint()..color = _offColor.withValues(alpha: .11 * brightness),
      );
    }
  }

  void _drawPunctuation(Canvas canvas, double x, String char) {
    final cx = x + 11.5;
    final centres = char == ':' ? const [37.0, 63.0] : const [90.0];
    const r = 5.5;
    for (final cy in centres) {
      canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..color = _glowColor.withValues(alpha: .5 * brightness)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()..color = _onColor.withValues(alpha: brightness),
      );
    }
  }

  Path _path(double x, int seg) {
    final left = x + x0;
    final right = left + w;
    final midY = y0 + h / 2;
    final lx = left + t / 2; // centre of the left vertical column
    final rx = right - t / 2; // centre of the right vertical column

    // Horizontal bar centred on [cy]. Its solid body only starts a full
    // thickness (plus gap) in from each end, so it clears the vertical columns
    // and the pointed tips leave a clean diagonal notch at every corner.
    Path horizontal(double cy) => Path()
      ..moveTo(left + t / 2 + gap, cy)
      ..lineTo(left + t + gap, cy - t / 2)
      ..lineTo(right - t - gap, cy - t / 2)
      ..lineTo(right - t / 2 - gap, cy)
      ..lineTo(right - t - gap, cy + t / 2)
      ..lineTo(left + t + gap, cy + t / 2)
      ..close();

    // The end that meets a top/bottom bar needs a full clearance; the end that
    // meets the middle bar is kept tight so the two half-columns nearly touch
    // across the centre instead of leaving a big gap.
    final outer = t / 2 + gap;
    final inner = gap;

    // Vertical bar centred on [cx] from [top] to [bot]; [ti]/[bi] are the tip
    // insets at the top and bottom ends.
    Path vertical(double cx, double top, double bot, double ti, double bi) =>
        Path()
          ..moveTo(cx, top + ti)
          ..lineTo(cx + t / 2, top + ti + t / 2)
          ..lineTo(cx + t / 2, bot - bi - t / 2)
          ..lineTo(cx, bot - bi)
          ..lineTo(cx - t / 2, bot - bi - t / 2)
          ..lineTo(cx - t / 2, top + ti + t / 2)
          ..close();

    return switch (seg) {
      0 => horizontal(y0 + t / 2), // top
      1 => vertical(rx, y0, midY, outer, inner), // top-right
      2 => vertical(rx, midY, y0 + h, inner, outer), // bottom-right
      3 => horizontal(y0 + h - t / 2), // bottom
      4 => vertical(lx, midY, y0 + h, inner, outer), // bottom-left
      5 => vertical(lx, y0, midY, outer, inner), // top-left
      _ => horizontal(midY), // middle
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
    // A key with no onTap is not pressable; render it as a dim, recessed,
    // shadowless grey cap so it reads as disabled. `active` (gold) is reserved
    // for a genuine toggle that IS still pressable, e.g. 夜間加成 while running.
    final disabled = widget.onTap == null;
    final Color bgColor = disabled
        ? const Color(0xff33373f)
        : (widget.active
            ? const Color(0xffd6ae58)
            : const Color(0xffe5e0cf));
    final Color textColor =
        disabled ? const Color(0xff70747d) : const Color(0xff252831);
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
                  color: bgColor,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _isPressed
                        ? const Color(0xff6a6251)
                        : (disabled
                            ? const Color(0xff4a4e56)
                            : const Color(0xfff8f3df)),
                    width: _isPressed ? 3 : 2,
                  ),
                  boxShadow: (_isPressed || disabled)
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
                        color: textColor,
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
