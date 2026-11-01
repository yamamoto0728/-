// list.json（一覧）と det/*.html（切れていた授業のページ）から、授業名 → [学期, [曜日時限…], 教室] の表を作る
// node sylbuild.js <sylフォルダ> <courses-shakai.js> <出力 .js>
const fs = require('fs'), path = require('path');
const [dir, coursesFile, outFile] = process.argv.slice(2);
const L = JSON.parse(fs.readFileSync(path.join(dir, 'list.json'), 'utf8'));
const strip = x => x.replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/[\s　]+/g, ' ').trim();
// 全角の英数字・記号を半角に（授業名の照合と教室名の変換用）
const half = s => String(s || '').replace(/[！-～]/g, c => String.fromCharCode(c.charCodeAt(0) - 0xFEE0)).replace(/　/g, ' ');
const key = s => half(s).replace(/\s+/g, '').toLowerCase();

// 切れていた授業は、授業のページの値で上書きする
for (const x of L) {
  const f = path.join(dir, 'det', x.id + '.html');
  if (!fs.existsSync(f)) continue;
  const s = fs.readFileSync(f, 'utf8');
  const field = jp => { const m = s.match(new RegExp(jp + '[\\s\\S]*?</t[hd]>\\s*<td[^>]*>([\\s\\S]*?)</td>')); return m ? strip(m[1]) : ''; };
  const sl = field('曜日・時限'), rm = field('教室名称');
  if (sl) x.slots = sl; if (rm) x.room = rm;
}

// シラバスの教室名 → ちかくの教室の一覧（rooms-tama.js）の名前。一覧に無い場所（体育棟・オンラインなど）は null
const A = [].concat(r(301, 306), r(401, 408), r(501, 504), r(515, 520), r(611, 622), r(711, 722)).map(String);
const Bsha = ['102', '103', '104', '105', '106', '201', '202', '203'];
function r(a, b) { return Array.from({ length: b - a + 1 }, (_, i) => a + i); }
function roomName(raw) {
  const s = half(raw).replace(/\s+/g, '').replace(/[-－]/g, '-');
  let m;
  if ((m = s.match(/^社(\d{3})$/))) { const n = m[1]; if (n === '101') return 'メディア表現実習室'; if (A.includes(n)) return '社会A' + n; if (Bsha.includes(n)) return '社会B' + n; return null; }
  if ((m = s.match(/^B(\d{3})$/i))) return ['201', '202', '301'].includes(m[1]) ? 'B' + m[1] : null;
  if ((m = s.match(/^情報実習室(\d)$/))) return '総合棟 情報実習室' + m[1];
  if ((m = s.match(/^CALL-([ABC])$/i))) return '総合棟 CALL教室' + m[1].toUpperCase();
  if ((m = s.match(/^経済?(\d{3})$/))) { const n = m[1]; if (['101', '102', '103', '201', '202', '203'].includes(n) && /^経済/.test(s)) return '経済C' + n;
    if (['304', '305', '306', '307', '204', '205', '206'].includes(n)) return '11号館' + n; if (/^1[12]\d|^2[12]\d|^3[12]\d/.test(n)) return '経済B' + n; return null; }
  return null;
}
const DOW = { 月: 1, 火: 2, 水: 3, 木: 4, 金: 5, 土: 6 };
const slotsOf = s => [...half(s).matchAll(/([月火水木金土])(\d)/g)].map(m => DOW[m[1]] + '-' + m[2]);
const termOf = t => /春/.test(t) ? 's' : /秋/.test(t) ? 'f' : /年間/.test(t) ? 'y' : '';

// 外すもの：Basic English・体育／スポーツ系・第二外国語（あおの指示「数が多いのでスキップ」）
const SKIP = /Basic English|体育|スポーツ総合|ドイツ語|フランス語|スペイン語|中国語|朝鮮語|韓国語|ロシア語|イタリア語|日本語/i;
const src = fs.readFileSync(coursesFile, 'utf8');
const official = new Function(src + ';return OFFICIAL_COURSES;')();
const out = {}, miss = [], noRoom = [];
for (const name of official) {
  if (SKIP.test(half(name))) continue;
  // 一覧で「…」と切れている授業名（英語の授業など）は、切れる前までが同じなら同じ授業とみなす
  const rows = L.filter(x => { const k = key(x.name); if (/\.\.\.$|…$/.test(k)) { const p = k.replace(/\.\.\.$|…$/, ''); return p.length >= 8 && key(name).startsWith(p); } return k === key(name); });
  if (!rows.length) { miss.push(name); continue; }
  const ent = [];
  for (const x of rows) {
    const rooms = x.room.split(/[,、]\s*/).map(roomName).filter(Boolean), sl = slotsOf(x.slots), t = termOf(x.term);
    if (!rooms.length || !sl.length || !t) continue;
    const e = [t, sl, rooms[0]], k = JSON.stringify(e);
    if (!ent.some(y => JSON.stringify(y) === k)) ent.push(e);
  }
  if (ent.length) out[name] = ent; else noRoom.push(name);
}
const n = Object.keys(out).length;
const body = `// 社会学部の授業（tama/courses-shakai.js の正式名称）ごとの、開講時期・曜日時限・教室。時間割で授業を選ぶと、教室を自動で入れるのに使う（2026年度）。
// 2026-11-01 あおの依頼「授業を選んだら、シラバスに書いてある教室が教室名の一覧から勝手に選ばれるとうれしい。春学期と秋学期に気を付けて。Basic English・体育・第二外国語はスキップ」で作った。
// 出どころ：法政大学Webシラバス「社会学部 全科目一覧」の 開講時期・曜日・時限・教室名称（一覧で「…」と切れていた60件は授業のページから）。
// 1件は [学期, [曜日-時限…], 教室]。学期は s=春学期・f=秋学期・y=年間。曜日は 1=月〜6=土。教室は rooms-tama.js の名前（社４０８ → 社会A408 のように直した）。
// 体育棟・オンラインなど、教室の一覧に無い場所の授業は入れていない。年度が変わったら作り直す（作り方は CLAUDE.md の 2026-11-01 の記録）。
const COURSE_ROOMS={
${Object.entries(out).map(([k, v]) => '  ' + JSON.stringify(k) + ':' + JSON.stringify(v)).join(',\n')}
};
`;
fs.writeFileSync(outFile, body);
console.log('courses with rooms', n, '/ official (after skip)', official.filter(x => !SKIP.test(half(x))).length, '| not in list', miss.length, '| no mappable room', noRoom.length);
console.log('miss sample', miss.slice(0, 15).join(' / '));
console.log('noRoom sample', noRoom.slice(0, 15).join(' / '));
const unk = {}; L.forEach(x => x.room.split(/[,、]\s*/).forEach(rw => { if (rw && !roomName(rw)) unk[rw] = (unk[rw] || 0) + 1; })); console.log('unmapped rooms', JSON.stringify(unk));
const multi = Object.entries(out).filter(([k, v]) => v.length > 1).length; console.log('courses with >1 entry', multi);
