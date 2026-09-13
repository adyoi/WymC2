/* Shared dashboard helpers */

function esc(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
}

/* Server timestamps are naive UTC strings "YYYY-MM-DD HH:MM:SS" */
function ago(ts) {
  if (!ts) return '-';
  const d = new Date(String(ts).replace(' ', 'T') + 'Z');
  if (isNaN(d.getTime())) return '-';
  const diff = (Date.now() - d.getTime()) / 1000;
  if (diff < 5) return 'now';
  if (diff < 60) return Math.floor(diff) + 's ago';
  if (diff < 3600) return Math.floor(diff / 60) + 'm ago';
  if (diff < 86400) return Math.floor(diff / 3600) + 'h ago';
  return Math.floor(diff / 86400) + 'd ago';
}
