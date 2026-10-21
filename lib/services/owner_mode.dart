import 'package:flutter/foundation.dart';

/// Sesión del propietario (en memoria: se cierra al cerrar la app). Con el
/// PIN, el propietario ve las carreras que borró el conductor y puede
/// restaurarlas o borrarlas definitivamente.
class OwnerMode {
  static final ValueNotifier<bool> unlocked = ValueNotifier(false);
}
