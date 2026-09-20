/// Core fare calculation is kept independent from Flutter widgets so that
/// other city rules and meter skins can share the same trip state.
class TaipeiFareRules {
  const TaipeiFareRules({
    this.baseFare = 85,
    this.baseDistanceMeters = 1250,
    this.distanceStepMeters = 200,
    this.waitingStepSeconds = 60,
    this.stepFare = 5,
    this.nightSurcharge = 20,
    this.slowSpeedMetersPerSecond = 5 / 3.6,
  });

  final int baseFare;
  final int baseDistanceMeters;
  final int distanceStepMeters;
  final int waitingStepSeconds;
  final int stepFare;
  final int nightSurcharge;
  final double slowSpeedMetersPerSecond;

  bool isNightStart(DateTime time) => time.hour >= 23 || time.hour < 6;

  int fareFor({
    required double distanceMeters,
    required Duration waitingTime,
    required DateTime startedAt,
    bool nightSurchargeApplied = false,
  }) {
    final distanceSteps =
        ((distanceMeters - baseDistanceMeters).clamp(0.0, double.infinity) /
                distanceStepMeters)
            .floor();
    final waitingSteps = waitingTime.inSeconds ~/ waitingStepSeconds;
    return baseFare +
        (nightSurchargeApplied || isNightStart(startedAt)
            ? nightSurcharge
            : 0) +
        (distanceSteps + waitingSteps) * stepFare;
  }
}

class TripReading {
  const TripReading({
    required this.startedAt,
    required this.elapsed,
    required this.distanceMeters,
    required this.billableDistanceMeters,
    required this.waitingTime,
    required this.fare,
    required this.accuracyMeters,
    required this.speedMetersPerSecond,
  });

  final DateTime startedAt;
  final Duration elapsed;

  /// All valid movement, shown to the rider as trip distance.
  final double distanceMeters;

  /// Distance accumulated while above the 5 km/h delayed-time threshold.
  final double billableDistanceMeters;
  final Duration waitingTime;
  final int fare;
  final double? accuracyMeters;
  final double speedMetersPerSecond;
}

/// Receives already-validated GPS samples. Platform-specific positioning stays
/// in the UI layer, making this class testable and ready for other platforms.
class TaxiMeterController {
  TaxiMeterController({this.rules = const TaipeiFareRules()});

  final TaipeiFareRules rules;
  DateTime? _startedAt;
  DateTime? _lastAccountedAt;
  DateTime? _lastSampleAt;
  double? _lastLatitude;
  double? _lastLongitude;
  double _distanceMeters = 0;
  double _billableDistanceMeters = 0;
  Duration _waitingTime = Duration.zero;
  double _speedMetersPerSecond = 0;
  double? _accuracyMeters;
  DateTime? _pausedAt;
  Duration _pausedDuration = Duration.zero;
  bool _manualNightSurcharge = false;

  bool get isRunning => _startedAt != null;
  bool get nightSurchargeActive =>
      _manualNightSurcharge ||
      (_startedAt != null && rules.isNightStart(_startedAt!));

  TripReading? get reading {
    final start = _startedAt;
    if (start == null) return null;
    return TripReading(
      startedAt: start,
      elapsed:
          (_pausedAt ?? DateTime.now()).difference(start) - _pausedDuration,
      distanceMeters: _distanceMeters,
      billableDistanceMeters: _billableDistanceMeters,
      waitingTime: _waitingTime,
      fare: rules.fareFor(
        distanceMeters: _billableDistanceMeters,
        waitingTime: _waitingTime,
        startedAt: start,
        nightSurchargeApplied: _manualNightSurcharge,
      ),
      accuracyMeters: _accuracyMeters,
      speedMetersPerSecond: _speedMetersPerSecond,
    );
  }

  void start(DateTime now) {
    _startedAt = now;
    _lastAccountedAt = now;
    _lastSampleAt = null;
    _lastLatitude = null;
    _lastLongitude = null;
    _distanceMeters = 0;
    _billableDistanceMeters = 0;
    _waitingTime = Duration.zero;
    _speedMetersPerSecond = 0;
    _accuracyMeters = null;
    _pausedAt = null;
    _pausedDuration = Duration.zero;
    _manualNightSurcharge = false;
  }

  void pause(DateTime now) {
    if (!isRunning || _pausedAt != null) return;
    tick(now);
    _pausedAt = now;
  }

  /// Restarts accounting after a UI-level pause without charging the paused
  /// interval or connecting a GPS segment across that interval.
  void resume(DateTime now) {
    if (!isRunning) return;
    final pausedAt = _pausedAt;
    if (pausedAt != null && now.isAfter(pausedAt)) {
      _pausedDuration += now.difference(pausedAt);
    }
    _pausedAt = null;
    _lastAccountedAt = now;
    _lastSampleAt = null;
    _lastLatitude = null;
    _lastLongitude = null;
    _speedMetersPerSecond = 0;
  }

  /// The physical 夜間加成 key manually applies the one-time night surcharge.
  /// A trip that starts during the regulated night period stays surcharged even
  /// when this manual setting is turned off.
  void setNightSurcharge(bool enabled) {
    if (!isRunning) return;
    _manualNightSurcharge = enabled;
  }

  /// Advances a deliberate simulation without requiring a GPS reading.
  /// Moving is billed by distance; idle time follows Taipei's delayed-time rule.
  void advanceSimulation({
    required DateTime now,
    required bool moving,
    double speedMetersPerSecond = 80 / 3.6,
  }) {
    final last = _lastAccountedAt;
    if (!isRunning || last == null || !now.isAfter(last)) return;
    final elapsed = now.difference(last);
    if (moving) {
      final meters = elapsed.inMilliseconds / 1000 * speedMetersPerSecond;
      _distanceMeters += meters;
      _billableDistanceMeters += meters;
      _speedMetersPerSecond = speedMetersPerSecond;
    } else {
      _waitingTime += elapsed;
      _speedMetersPerSecond = 0;
    }
    _lastAccountedAt = now;
    _lastSampleAt = now;
    _accuracyMeters = null;
  }

  void reset() {
    _startedAt = null;
    _lastAccountedAt = null;
    _lastSampleAt = null;
    _lastLatitude = null;
    _lastLongitude = null;
    _distanceMeters = 0;
    _billableDistanceMeters = 0;
    _waitingTime = Duration.zero;
    _accuracyMeters = null;
    _pausedAt = null;
    _pausedDuration = Duration.zero;
    _manualNightSurcharge = false;
  }

  /// Delayed-time rule: whenever the meter cannot bill distance right now the
  /// waiting-time clock keeps running. That is the case when the vehicle is
  /// crawling or stopped (speed at or below the slow threshold), or when GPS has
  /// gone stale so no new distance is arriving at all (e.g. parked, where a
  /// distance-filtered GPS stops emitting samples). In short: if distance is not
  /// increasing, time is.
  void tick(DateTime now) {
    final last = _lastAccountedAt;
    if (!isRunning || last == null || !now.isAfter(last)) return;
    final gpsStale =
        _lastSampleAt == null ||
        now.difference(_lastSampleAt!) > const Duration(seconds: 5);
    final movingFast =
        !gpsStale && _speedMetersPerSecond > rules.slowSpeedMetersPerSecond;
    if (!movingFast) {
      _waitingTime += now.difference(last);
    }
    _lastAccountedAt = now;
  }

  /// [distanceBetween] should use the platform's geodesic distance. Readings
  /// over 45 m accuracy are ignored to limit urban GPS drift. At <= 5 km/h,
  /// only delayed-time fare accrues; distance remains visible but is not also
  /// charged, avoiding a double jump while crawling in traffic.
  void addGpsSample({
    required DateTime timestamp,
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required double speedMetersPerSecond,
    required double Function(double, double, double, double) distanceBetween,
  }) {
    if (!isRunning || accuracyMeters > 45) return;
    tick(timestamp);
    _accuracyMeters = accuracyMeters;

    if (_lastLatitude != null && _lastLongitude != null) {
      final segment = distanceBetween(
        _lastLatitude!,
        _lastLongitude!,
        latitude,
        longitude,
      );
      // Ignore tiny movements which are predominantly GPS noise.
      if (segment >= 3) {
        _distanceMeters += segment;
        if (speedMetersPerSecond > rules.slowSpeedMetersPerSecond) {
          _billableDistanceMeters += segment;
        }
      }
    }
    _lastLatitude = latitude;
    _lastLongitude = longitude;
    _lastSampleAt = timestamp;
    _speedMetersPerSecond = speedMetersPerSecond.isFinite
        ? speedMetersPerSecond.clamp(0, 80)
        : 0;
  }
}
