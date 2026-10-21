import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../models/seat.dart';
import '../models/trip_record.dart';
import '../utils/format.dart';
import '../utils/trip_stats.dart';

/// Genera Excel/PDF de la bitácora y el aviso para el vehículo, y abre el
/// menú de compartir de Android (WhatsApp, correo, Drive…).
class ExportService {
  static String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}';
  }

  static String _seats(TripRecord t) =>
      t.seats.isEmpty ? '-' : t.seats.map((s) => s.label).join(', ');

  static Future<File> _write(String name, List<int> bytes) async {
    final f = File(p.join((await getTemporaryDirectory()).path, name));
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  static Future<void> _share(File f, String subject) =>
      SharePlus.instance.share(ShareParams(
        files: [XFile(f.path)],
        subject: subject,
      ));

  // -------------------------------------------------------------------------
  // Excel
  // -------------------------------------------------------------------------

  static Future<void> shareExcel(List<TripRecord> trips) async {
    final book = xl.Excel.createExcel();
    final defaultSheet = book.getDefaultSheet()!;
    book.rename(defaultSheet, 'Carreras');
    final header = xl.CellStyle(
      bold: true,
      backgroundColorHex: xl.ExcelColor.fromHexString('#FFC107'),
    );

    void addSheet(String name, List<String> headers, List<List<xl.CellValue?>> rows,
        List<double> widths) {
      final sheet = book[name];
      sheet.appendRow([for (final h in headers) xl.TextCellValue(h)]);
      for (var c = 0; c < headers.length; c++) {
        sheet
            .cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0))
            .cellStyle = header;
        sheet.setColumnWidth(c, widths[c]);
      }
      rows.forEach(sheet.appendRow);
    }

    final ordered = trips.reversed.toList(); // cronológico
    addSheet(
      'Carreras',
      ['N.º', 'Fecha', 'Inicio', 'Fin', 'Duración', 'Duración (min)',
        'Máx. pasajeros', 'Asientos', 'Conductor', 'Km', 'Origen', 'Destino',
        'Fuente'],
      [
        for (var i = 0; i < ordered.length; i++)
          [
            xl.IntCellValue(i + 1),
            xl.TextCellValue(formatDate(ordered[i].start)),
            xl.TextCellValue(formatTime(ordered[i].start)),
            xl.TextCellValue(formatTime(ordered[i].end)),
            xl.TextCellValue(formatDuration(ordered[i].duration)),
            xl.DoubleCellValue(
                (ordered[i].duration.inSeconds / 60 * 10).round() / 10),
            xl.IntCellValue(ordered[i].maxPassengers),
            xl.TextCellValue(_seats(ordered[i])),
            xl.TextCellValue(ordered[i].driver ?? ''),
            ordered[i].distanceKm == null
                ? null
                : xl.DoubleCellValue(
                    (ordered[i].distanceKm! * 10).round() / 10),
            xl.TextCellValue(ordered[i].origin?.label ?? ''),
            xl.TextCellValue(ordered[i].destination?.label ?? ''),
            xl.TextCellValue(ordered[i].source == TripSource.live
                ? 'En vivo'
                : 'Simulación'),
          ],
      ],
      [6, 12, 10, 10, 10, 14, 15, 30, 18, 8, 34, 34, 12],
    );
    addSheet(
      'Pasajeros',
      ['Carrera N.º', 'Pasajero', 'Asiento', 'Entrada', 'Salida', 'Duración'],
      [
        for (var i = 0; i < ordered.length; i++)
          for (final s in ordered[i].passengers)
            [
              xl.IntCellValue(i + 1),
              xl.IntCellValue(s.number),
              xl.TextCellValue(s.seat?.label ?? 'Sin asiento'),
              xl.TextCellValue(formatTime(s.enter)),
              xl.TextCellValue(formatTime(s.exit)),
              xl.TextCellValue(formatDuration(s.duration)),
            ],
      ],
      [12, 10, 16, 10, 10, 10],
    );
    final hours = tripsPerHour(trips);
    addSheet(
      'Por hora',
      ['Hora', 'Carreras'],
      [
        for (var h = 0; h < 24; h++)
          [xl.TextCellValue('${h.toString().padLeft(2, '0')}:00'),
            xl.IntCellValue(hours[h])],
      ],
      [10, 10],
    );

    final f = await _write('taxiff_bitacora_${_stamp()}.xlsx', book.encode()!);
    await _share(f, 'Bitácora de carreras Taxiff');
  }

  // -------------------------------------------------------------------------
  // PDF
  // -------------------------------------------------------------------------

  static Future<pw.ThemeData> _theme() async => pw.ThemeData.withFont(
        base: pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Regular.ttf')),
        bold: pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Bold.ttf')),
      );

  static const _amber = PdfColor.fromInt(0xFFFFB300);
  static const _grey = PdfColor.fromInt(0xFF757575);

  static Future<void> sharePdfReport(List<TripRecord> trips,
      {String filterLabel = 'Todas'}) async {
    final doc = pw.Document(theme: await _theme());
    final ordered = trips.reversed.toList();
    final hours = tripsPerHour(trips);
    final maxH = hours.reduce((a, b) => a > b ? a : b);
    final usage = seatUsage(trips);

    pw.Widget stat(String v, String l) => pw.Expanded(
          child: pw.Column(children: [
            pw.Text(v,
                style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            pw.Text(l, style: const pw.TextStyle(fontSize: 9, color: _grey)),
          ]),
        );

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      header: (ctx) => pw.Container(
        padding: const pw.EdgeInsets.only(bottom: 8),
        decoration: const pw.BoxDecoration(
            border: pw.Border(bottom: pw.BorderSide(color: _amber, width: 2))),
        child: pw.Row(children: [
          pw.Text('Taxiff · Reporte de carreras',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.Spacer(),
          pw.Text('${formatDate(DateTime.now())} · $filterLabel',
              style: const pw.TextStyle(fontSize: 9, color: _grey)),
        ]),
      ),
      footer: (ctx) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Página ${ctx.pageNumber} de ${ctx.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: _grey)),
      ),
      build: (ctx) => [
        pw.SizedBox(height: 12),
        pw.Row(children: [
          stat('${trips.length}', 'carreras'),
          stat(formatDuration(totalDuration(trips)), 'tiempo total'),
          stat(formatDuration(averageDuration(trips)), 'duración media'),
          stat('${trips.fold(0, (s, t) => s + t.maxPassengers)}', 'pasajeros'),
        ]),
        pw.SizedBox(height: 20),
        pw.Text('Carreras por hora del día',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 8),
        pw.SizedBox(
          height: 110,
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              for (var h = 0; h < 24; h++)
                pw.Expanded(
                  child: pw.Column(
                    mainAxisAlignment: pw.MainAxisAlignment.end,
                    children: [
                      if (hours[h] > 0)
                        pw.Text('${hours[h]}',
                            style: const pw.TextStyle(fontSize: 7)),
                      pw.Container(
                        margin: const pw.EdgeInsets.symmetric(horizontal: 1.5),
                        height: maxH == 0 ? 0 : 80.0 * hours[h] / maxH,
                        color: _amber,
                      ),
                      pw.SizedBox(height: 2),
                      pw.Text(h % 3 == 0 ? '$h' : '',
                          style: const pw.TextStyle(fontSize: 7, color: _grey)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        pw.SizedBox(height: 16),
        pw.Text('Uso de asientos',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text(
          SeatId.values
              .where((s) => s != SeatId.driver)
              .map((s) => '${s.label}: ${usage[s]}')
              .join('   ·   '),
          style: const pw.TextStyle(fontSize: 10),
        ),
        pw.SizedBox(height: 16),
        pw.TableHelper.fromTextArray(
          headers: ['N.º', 'Fecha', 'Inicio', 'Fin', 'Duración', 'Pax', 'Km',
              'Asientos', 'Conductor'],
          data: [
            for (var i = 0; i < ordered.length; i++)
              [
                '${i + 1}',
                formatDate(ordered[i].start),
                formatTime(ordered[i].start),
                formatTime(ordered[i].end),
                formatDuration(ordered[i].duration),
                '${ordered[i].maxPassengers}',
                ordered[i].distanceKm?.toStringAsFixed(1) ?? '-',
                ordered[i].seats.isEmpty
                    ? '-'
                    : ordered[i].seats.map((s) => s.short).join(' '),
                ordered[i].driver ?? '-',
              ],
          ],
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
          headerDecoration: const pw.BoxDecoration(color: _amber),
          cellStyle: const pw.TextStyle(fontSize: 9),
          oddRowDecoration:
              const pw.BoxDecoration(color: PdfColor.fromInt(0xFFF5F5F5)),
          cellAlignment: pw.Alignment.centerLeft,
        ),
        pw.SizedBox(height: 8),
        pw.Text(
          'Asientos: C conductor, CP copiloto, TI trasero izq., '
          'TC trasero centro, TD trasero der.',
          style: const pw.TextStyle(fontSize: 8, color: _grey),
        ),
      ],
    ));

    final f = await _write('taxiff_reporte_${_stamp()}.pdf', await doc.save());
    await _share(f, 'Reporte de carreras Taxiff');
  }

  /// Cartel para pegar en el vehículo informando del conteo automático.
  /// [photos]: si la app guarda fotos de evidencia, el cartel lo dice.
  static Future<void> shareVehicleNotice({bool photos = false}) async {
    final doc = pw.Document(theme: await _theme());
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a5,
      margin: const pw.EdgeInsets.all(28),
      build: (ctx) => pw.Container(
        padding: const pw.EdgeInsets.all(20),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: _amber, width: 4),
          borderRadius: pw.BorderRadius.circular(12),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text('AVISO',
                style: pw.TextStyle(
                    fontSize: 40, fontWeight: pw.FontWeight.bold, color: _amber)),
            pw.SizedBox(height: 12),
            pw.Text(
              'Este vehículo utiliza una cámara con conteo automático de '
              'pasajeros.',
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 16),
            for (final line in [
              'La imagen se analiza solo dentro del dispositivo.',
              if (photos) ...[
                'No se graba vídeo ni se envía nada a internet.',
                'Se guardan fotos de baja resolución del viaje en el '
                    'dispositivo, solo como registro del servicio, y se '
                    'borran automáticamente.',
              ] else
                'No se graban, guardan ni envían imágenes ni vídeo.',
              'Se registra la hora de inicio y fin del viaje y el '
                  'número de pasajeros.',
              'No se identifica a ninguna persona.',
            ])
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 4),
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Container(
                      width: 8,
                      height: 8,
                      margin: const pw.EdgeInsets.only(top: 5, right: 8),
                      decoration: const pw.BoxDecoration(
                          color: _amber, shape: pw.BoxShape.circle),
                    ),
                    pw.Expanded(
                        child: pw.Text(line,
                            style: const pw.TextStyle(fontSize: 13))),
                  ],
                ),
              ),
            pw.Spacer(),
            pw.Text('Si tiene dudas, consulte al conductor.',
                style: const pw.TextStyle(fontSize: 11, color: _grey)),
          ],
        ),
      ),
    ));
    final f = await _write('taxiff_aviso_vehiculo.pdf', await doc.save());
    await _share(f, 'Aviso de conteo de pasajeros');
  }
}
