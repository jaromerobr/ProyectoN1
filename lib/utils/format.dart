String _two(int n) => n.toString().padLeft(2, '0');

/// 75 s → "01:15", 3725 s → "1:02:05".
String formatDuration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(s)}' : '${_two(m)}:${_two(s)}';
}

/// 45 s → "45 s", 18 min 20 s → "18 min", 65 min → "1 h 05 min".
String humanDuration(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds} s';
  if (d.inHours < 1) return '${d.inMinutes} min';
  return '${d.inHours} h ${_two(d.inMinutes % 60)} min';
}

String formatTime(DateTime t) =>
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

String formatHm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

String formatDate(DateTime t) => '${_two(t.day)}/${_two(t.month)}/${t.year}';

const _weekdays = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];
const _weekdaysLong = [
  'Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'
];
const _months = [
  'ene', 'feb', 'mar', 'abr', 'may', 'jun',
  'jul', 'ago', 'sep', 'oct', 'nov', 'dic'
];

String weekdayInitial(DateTime d) => 'LMXJVSD'[d.weekday - 1];

/// "Hoy", "Ayer" o "Lunes 13 oct".
String dayLabel(DateTime d, DateTime now) {
  final day = DateTime(d.year, d.month, d.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Hoy';
  if (diff == 1) return 'Ayer';
  return '${_weekdaysLong[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
}

/// "lun 13 oct".
String shortDate(DateTime d) =>
    '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}';
