import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/trip_record.dart';
import 'evidence_store.dart';

/// Bitácora local de carreras (SQLite).
///
/// v1: tabla `carreras`.
/// v2: columna `asientos` + tabla `pasajeros` (entrada/salida de cada uno).
/// v3: `pasajeros.recorrido` (JSON con los tramos por asiento → cambios de
///     asiento).
/// v4: conductor, turno, origen/destino GPS y distancia + tabla `turnos`.
/// v5: `carreras.evidencias` (carpeta con las fotos de la carrera).
/// v6: `carreras.borrada` (borrado lógico: el conductor no la ve, el
///     propietario sí).
class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();

  Database? _db;

  static const _passengersTable = '''
    CREATE TABLE pasajeros (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      carrera_id INTEGER NOT NULL REFERENCES carreras(id) ON DELETE CASCADE,
      numero INTEGER NOT NULL,
      asiento TEXT,
      entrada INTEGER NOT NULL,
      salida INTEGER NOT NULL,
      recorrido TEXT
    )''';

  static const _shiftsTable = '''
    CREATE TABLE turnos (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      conductor TEXT NOT NULL,
      inicio INTEGER NOT NULL,
      fin INTEGER
    )''';

  /// Columnas añadidas en v4 a `carreras`.
  static const _v4Columns = [
    'conductor TEXT',
    'turno_id INTEGER',
    'lat_ini REAL',
    'lng_ini REAL',
    'dir_ini TEXT',
    'lat_fin REAL',
    'lng_fin REAL',
    'dir_fin TEXT',
    'distancia_m REAL',
  ];

  /// Columnas añadidas en v5 a `carreras`.
  static const _v5Columns = ['evidencias TEXT'];

  /// Columnas añadidas en v6 a `carreras`.
  static const _v6Columns = ['borrada INTEGER'];

  Future<Database> get database async =>
      _db ??= await openDatabase(
        p.join(await getDatabasesPath(), 'taxiff.db'),
        version: 6,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE carreras (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              timestamp_inicio INTEGER NOT NULL,
              timestamp_fin INTEGER NOT NULL,
              duracion_ms INTEGER NOT NULL,
              max_pasajeros INTEGER NOT NULL,
              fuente TEXT NOT NULL,
              asientos TEXT NOT NULL DEFAULT '',
              ${[..._v4Columns, ..._v5Columns, ..._v6Columns].join(',\n              ')}
            )''');
          await db.execute(_passengersTable);
          await db.execute(_shiftsTable);
        },
        onUpgrade: (db, from, _) async {
          if (from < 2) {
            await db.execute(
                "ALTER TABLE carreras ADD COLUMN asientos TEXT NOT NULL DEFAULT ''");
            await db.execute(_passengersTable);
          }
          if (from == 2) {
            await db.execute('ALTER TABLE pasajeros ADD COLUMN recorrido TEXT');
          }
          if (from < 4) {
            for (final c in _v4Columns) {
              await db.execute('ALTER TABLE carreras ADD COLUMN $c');
            }
            await db.execute(_shiftsTable);
          }
          if (from < 5) {
            for (final c in _v5Columns) {
              await db.execute('ALTER TABLE carreras ADD COLUMN $c');
            }
          }
          if (from < 6) {
            for (final c in _v6Columns) {
              await db.execute('ALTER TABLE carreras ADD COLUMN $c');
            }
          }
        },
      );

  // --- Carreras ---------------------------------------------------------------

  Future<int> insertTrip(TripRecord trip) async {
    final db = await database;
    return db.transaction((txn) async {
      final id = await txn.insert('carreras', trip.toMap());
      for (final s in trip.passengers) {
        await txn.insert('pasajeros', s.toMap(id));
      }
      return id;
    });
  }

  /// Carreras, las más recientes primero. Las borradas solo aparecen con
  /// [includeDeleted] (modo propietario).
  Future<List<TripRecord>> trips(
      {TripSource? source, bool includeDeleted = false}) async {
    final db = await database;
    final where = [
      if (source != null) 'fuente = ?',
      if (!includeDeleted) 'borrada IS NULL',
    ];
    final rows = await db.query(
      'carreras',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: source == null ? null : [source.name],
      orderBy: 'timestamp_inicio DESC',
    );
    final pax = await db.query('pasajeros', orderBy: 'carrera_id, numero');
    final byTrip = <int, List<PassengerStint>>{};
    for (final r in pax) {
      byTrip
          .putIfAbsent(r['carrera_id'] as int, () => [])
          .add(PassengerStint.fromMap(r));
    }
    return [
      for (final r in rows)
        TripRecord.fromMap(r, byTrip[r['id'] as int] ?? const []),
    ];
  }

  /// Borrado del conductor: la carrera deja de verse, pero se conserva (con
  /// sus fotos) para el propietario.
  Future<void> deleteTrip(int id) async => (await database).update(
      'carreras', {'borrada': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?', whereArgs: [id]);

  /// Recupera una carrera borrada (propietario).
  Future<void> restoreTrip(int id) async => (await database).update(
      'carreras', {'borrada': null},
      where: 'id = ?', whereArgs: [id]);

  /// Borrado definitivo (propietario): carrera, pasajeros y fotos.
  Future<void> purgeTrip(int id) async {
    final db = await database;
    final rows = await db.query('carreras',
        columns: ['evidencias'], where: 'id = ?', whereArgs: [id]);
    for (final r in rows) {
      await EvidenceStore.deleteDir(r['evidencias'] as String?);
    }
    await db.delete('carreras', where: 'id = ?', whereArgs: [id]);
  }

  /// Borrado (lógico) de todas las carreras de una fuente.
  Future<void> deleteAll({TripSource? source}) async =>
      (await database).update(
        'carreras',
        {'borrada': DateTime.now().millisecondsSinceEpoch},
        where: source == null ? 'borrada IS NULL' : 'fuente = ? AND borrada IS NULL',
        whereArgs: source == null ? null : [source.name],
      );

  // --- Turnos -----------------------------------------------------------------

  Future<Shift?> activeShift() async {
    final rows = await (await database).query('turnos',
        where: 'fin IS NULL', orderBy: 'inicio DESC', limit: 1);
    return rows.isEmpty ? null : Shift.fromMap(rows.first);
  }

  /// Cierra el turno activo (si hay) y abre uno nuevo.
  Future<Shift> startShift(String driver, DateTime at) async {
    final db = await database;
    await db.update('turnos', {'fin': at.millisecondsSinceEpoch},
        where: 'fin IS NULL');
    final s = Shift(driver: driver, start: at);
    final id = await db.insert('turnos', s.toMap());
    return Shift(id: id, driver: driver, start: at);
  }

  Future<void> endShift(int id, DateTime at) async => (await database).update(
      'turnos', {'fin': at.millisecondsSinceEpoch},
      where: 'id = ?', whereArgs: [id]);

  Future<List<Shift>> shifts() async =>
      (await (await database).query('turnos', orderBy: 'inicio DESC'))
          .map(Shift.fromMap)
          .toList();
}
