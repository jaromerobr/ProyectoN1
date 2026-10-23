// Utilidades compartidas por las páginas del panel.
const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const dur = s => { s = Math.max(0, Math.round(s || 0)); const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60;
  return (h ? h + ':' + String(m).padStart(2, '0') : String(m).padStart(2, '0')) + ':' + String(x).padStart(2, '0'); };
// "45 s", "6 min 14 s", "1 h 05 min".
const durLarga = s => {
  s = Math.max(0, Math.round(s || 0));
  if (s < 60) return s + ' s';
  if (s < 3600) return Math.floor(s / 60) + ' min ' + (s % 60) + ' s';
  return Math.floor(s / 3600) + ' h ' + String(Math.floor(s / 60) % 60).padStart(2, '0') + ' min';
};
const hace = ts => { if (!ts) return 'nunca'; const s = Date.now() / 1000 - ts;
  return s < 60 ? 'hace ' + Math.round(s) + ' s' : s < 3600 ? 'hace ' + Math.round(s / 60) + ' min' : new Date(ts * 1000).toLocaleString(); };
const ESTADOS = { LIBRE: ['LIBRE', ''], CONFIRMANDO: ['CONFIRMANDO', 'amarillo'], EN_CARRERA: ['EN CARRERA', 'verde'] };

function pill(t) {
  if (!t.en_linea) return '<span class="pill">SIN CONEXIÓN</span>';
  const [txt, cls] = ESTADOS[t.estado] || ESTADOS.LIBRE;
  return `<span class="pill ${cls}">${txt}</span>`;
}

async function api(url, body) {
  const r = await fetch(url, body ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) } : {});
  if (!r.ok) throw new Error(r.status);
  return r.json();
}

function filaCarreraTitulo(conTaxi) {
  return `<tr class="m"><td>Inicio</td>${conTaxi ? '<td>Taxi</td>' : ''}<td>Duración</td><td>Pasajeros</td><td>Evidencia</td></tr>`;
}

// Línea de tiempo de una carrera: "14:05:10 suben 2 · 14:20:31 baja 1 · …".
function lineaDeTiempo(eventos) {
  return (eventos || []).map(([ts, tipo, k]) =>
    `${new Date(ts * 1000).toLocaleTimeString()} ${tipo === 'sube' ? (k > 1 ? 'suben ' : 'sube ') : (k > 1 ? 'bajan ' : 'baja ')}${k}`).join(' · ');
}

function filaCarrera(c, conTaxi) {
  const fotos = c.fotos.slice(0, 4).map(f => `<a href="/fotos/${f}" target="_blank"><img class="mini" src="/fotos/${f}" alt=""></a>`).join('');
  const distintos = c.pasajeros ?? c.max_pax;
  const pax = `<b>${distintos}</b>${distintos !== c.max_pax ? ` <span class="m">(máx. ${c.max_pax} a la vez)</span>` : ''}`;
  const linea = lineaDeTiempo(c.eventos);
  return `<tr class="${c.valida ? '' : 'descartada'}"><td>${new Date(c.inicio * 1000).toLocaleString()}` +
    (linea ? `<div class="m">${linea}</div>` : '') + `</td>` +
    (conTaxi ? `<td><a href="/taxi/${c.dispositivo}">${esc(c.nombre || c.dispositivo)}</a></td>` : '') +
    `<td>${dur(c.duracion)}${c.valida ? '' : ' <span class="m">(descartada: menos de 30 s)</span>'}</td><td>${pax}</td><td>${fotos}</td></tr>`;
}
