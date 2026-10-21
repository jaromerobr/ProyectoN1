import 'package:flutter/material.dart';

import '../models/app_settings.dart';

/// Explica qué datos se procesan. Con [requireAccept] se muestra al primer
/// uso y no se puede cerrar sin aceptar. Devuelve true si se aceptó.
Future<bool> showPrivacyNotice(BuildContext context,
    {required bool requireAccept}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: !requireAccept,
    builder: (ctx) => PopScope(
      canPop: !requireAccept,
      child: AlertDialog(
        icon: const Icon(Icons.privacy_tip_outlined, size: 36),
        title: const Text('Privacidad'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Item(Icons.phone_android,
                  'La imagen de la cámara se analiza solo en este teléfono. '
                  'No se usa internet.'),
              _Item(Icons.videocam_off,
                  'No se graba vídeo ni se envía nada a internet. Si activas '
                  '«Evidencias fotográficas», se guardan fotos pequeñas de '
                  'cada carrera solo en este teléfono y se borran solas en el '
                  'plazo que elijas.'),
              _Item(Icons.receipt_long,
                  'Solo se guarda la hora de inicio y fin de cada carrera, '
                  'cuántos pasajeros hubo y en qué asientos.'),
              _Item(Icons.face_retouching_off,
                  'No se reconoce ni identifica a ninguna persona: los '
                  'números (#12) solo duran mientras la persona está a la vista.'),
              _Item(Icons.campaign_outlined,
                  'Informa a los pasajeros. En Ajustes › Privacidad puedes '
                  'generar un cartel para el vehículo. Consulta la normativa '
                  'de protección de datos de tu país antes de usarla en '
                  'servicio real.'),
            ],
          ),
        ),
        actions: [
          if (requireAccept)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Entendido'),
            )
          else
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cerrar'),
            ),
        ],
      ),
    ),
  );
  if (ok == true && requireAccept) {
    final s = await AppSettings.load();
    await s.copyWith(privacyAccepted: true).save();
  }
  return ok == true;
}

class _Item extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Item(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      );
}
