// シラバスの一覧（p1〜p9.html）から、授業ごとに {id, code, name, term, slots, room} を取り出して list.json に書く
const fs = require('fs'), path = require('path');
const dir = process.argv[2];
const strip = x => x.replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/[\s　]+/g, ' ').trim();
const out = new Map();
for (let p = 1; p <= 9; p++) {
  const s = fs.readFileSync(path.join(dir, `p${p}.html`), 'utf8');
  for (const m of s.matchAll(/<tr class="jp" data-href=preview\.php\?no_id=(\d+)[^>]*>([\s\S]*?)<\/tr>/g)) {
    const id = m[1], cell = c => { const x = m[2].match(new RegExp(`<td lang="${c}"[^>]*>([\\s\\S]*?)</td>`)); return x ? strip(x[1]) : ''; };
    if (out.has(id)) continue;
    out.set(id, { id, code: cell('col5'), name: cell('col6'), term: cell('col10'), slots: cell('col11'), room: cell('col17') });
  }
}
const L = [...out.values()];
fs.writeFileSync(path.join(dir, 'list.json'), JSON.stringify(L, null, 1));
console.log('courses', L.length, 'truncated slots', L.filter(x => /\.\.\.|…/.test(x.slots)).length, 'truncated room', L.filter(x => /\.\.\.|…/.test(x.room)).length);
const rooms = {}; L.forEach(x => x.room.split(/[,、]\s*/).forEach(r => { r = r.replace(/\.\.\.$/, ''); rooms[r] = (rooms[r] || 0) + 1; }));
console.log(JSON.stringify(Object.entries(rooms).sort((a, b) => b[1] - a[1])));
console.log(JSON.stringify([...new Set(L.map(x => x.term.split('/')[0]))]));
