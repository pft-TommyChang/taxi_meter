import 'package:flutter_test/flutter_test.dart';
import 'package:taxi_meter/taxi_meter_controller.dart';

void main() {
  group('TaipeiFareRules', () {
    const rules = TaipeiFareRules();
    final daytime = DateTime(2026, 9, 20, 10);

    test('starts at NT\$85 for 1.25 km', () {
      expect(
        rules.fareFor(
          distanceMeters: 1250,
          waitingTime: Duration.zero,
          startedAt: daytime,
        ),
        85,
      );
    });

    test('adds NT\$5 for every 200 m and 60 seconds waiting', () {
      expect(
        rules.fareFor(
          distanceMeters: 1650,
          waitingTime: const Duration(seconds: 120),
          startedAt: daytime,
        ),
        105,
      );
    });

    test('applies night surcharge based on trip start', () {
      expect(
        rules.fareFor(
          distanceMeters: 0,
          waitingTime: Duration.zero,
          startedAt: DateTime(2026, 9, 20, 23),
        ),
        105,
      );
    });
  });

  test('does not charge distance and delayed time at the same time', () {
    final controller = TaxiMeterController();
    final start = DateTime(2026, 9, 20, 10);
    controller.start(start);
    controller.addGpsSample(
      timestamp: start,
      latitude: 25,
      longitude: 121,
      accuracyMeters: 5,
      speedMetersPerSecond: 0,
      distanceBetween: (_, _, _, _) => 0,
    );
    for (var seconds = 4; seconds <= 60; seconds += 4) {
      controller.addGpsSample(
        timestamp: start.add(Duration(seconds: seconds)),
        latitude: 25,
        longitude: 121,
        accuracyMeters: 5,
        speedMetersPerSecond: 0,
        distanceBetween: (_, _, _, _) => 0,
      );
    }
    controller.addGpsSample(
      timestamp: start.add(const Duration(seconds: 61)),
      latitude: 25,
      longitude: 121.001,
      accuracyMeters: 5,
      speedMetersPerSecond: 0,
      distanceBetween: (_, _, _, _) => 300,
    );

    final reading = controller.reading!;
    expect(reading.distanceMeters, 300);
    expect(reading.billableDistanceMeters, 0);
    expect(reading.fare, 90);
  });

  test('simulation moves at the configured speed and counts idle time', () {
    final controller = TaxiMeterController();
    final start = DateTime(2026, 9, 20, 10);
    controller.start(start);
    controller.advanceSimulation(
      now: start.add(const Duration(minutes: 1)),
      moving: true,
    );
    final movingReading = controller.reading!;
    controller.advanceSimulation(
      now: start.add(const Duration(minutes: 2)),
      moving: false,
    );

    final reading = controller.reading!;
    expect(reading.distanceMeters, closeTo(1333.33, .01));
    expect(movingReading.speedMetersPerSecond, closeTo(80 / 3.6, .01));
    expect(reading.speedMetersPerSecond, 0);
    expect(reading.waitingTime, const Duration(minutes: 1));
    expect(reading.fare, 90);
  });

  test(
    'pause freezes elapsed time and resume excludes the paused interval',
    () {
      final controller = TaxiMeterController();
      final start = DateTime(2026, 9, 20, 10);
      controller.start(start);

      controller.pause(start.add(const Duration(seconds: 10)));
      expect(controller.reading!.elapsed, const Duration(seconds: 10));

      controller.resume(start.add(const Duration(seconds: 40)));
      controller.pause(start.add(const Duration(seconds: 55)));
      expect(controller.reading!.elapsed, const Duration(seconds: 25));
    },
  );

  test('manual night surcharge immediately updates the active trip fare', () {
    final controller = TaxiMeterController();
    controller.start(DateTime(2026, 9, 20, 10));

    controller.setNightSurcharge(true);
    expect(controller.nightSurchargeActive, isTrue);
    expect(controller.reading!.fare, 105);

    controller.setNightSurcharge(false);
    expect(controller.nightSurchargeActive, isFalse);
    expect(controller.reading!.fare, 85);
  });
}
