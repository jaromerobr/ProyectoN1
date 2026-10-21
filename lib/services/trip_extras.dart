import '../models/app_settings.dart';
import '../models/trip_record.dart';
import 'announcer.dart';
import 'database_helper.dart';
import 'trip_location.dart';

/// Lo que acompaña a cada carrera además del conteo: aviso sonoro, GPS
/// (origen, destino, distancia) y el conductor del turno activo.
class TripExtras {
  final bool useGps;
  final Announcer announcer;
  final TripLocation location = TripLocation();

  TripExtras(AppSettings settings, {required bool gps})
      : useGps = gps && settings.gpsEnabled,
        announcer = Announcer(settings.announce);

  Future<void> onTripStarted() async {
    announcer.tripStarted();
    if (useGps) await location.start();
  }

  Future<TripRecord> enrich(TripRecord trip) async {
    var out = trip;
    if (useGps && location.active) {
      final (origin, dest, meters) = await location.stop();
      out = out.copyWith(
          origin: origin, destination: dest, distanceMeters: meters);
    }
    try {
      final shift = await DatabaseHelper.instance.activeShift();
      if (shift != null) {
        out = out.copyWith(driver: shift.driver, shiftId: shift.id);
      }
    } catch (_) {}
    announcer.tripEnded(trip.duration);
    return out;
  }

  void dispose() {
    location.dispose();
    announcer.dispose();
  }
}
