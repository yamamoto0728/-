// ちかく：アプリを閉じていても、学内ですれ違う（2026-11-05）。tama/bgloc.js の元。
// 包んだアプリ（D:\chikaku-app）の中でだけ動く。位置の部品は 10/29 の試作（D:\chikaku-proto-bgloc）と同じ Transistorsoft。
// 作り方（D:\chikaku-app で）：npm run bgloc → tama/bgloc.js ができる（esbuild で1つにまとめる）
//
// 動き（試作と同じ）：
//   ・ふだんは「キャンパスを覆う小さい円のどれかに入ったら起こして」とだけ頼んで寝ている（startGeofences）
//   ・円に入ったら位置を取り始める（start）。20m 動くごとに1回、止まって5分たったら休む。円からはっきり離れたらまた寝る
//   ・取った位置は、部品が自分でサーバー（tama_bg_ingest）に送る（アプリが閉じていても）。端末ごとの合言葉で本人を確かめる
//   ・サーバーは学内の位置だけを受け取り、学外の位置は捨てる。端末の中の記録は1日で消す
// キャンパスの形（起こす円）はページから受け取る（大学ごとの設定にするため）
import BackgroundGeolocation, { DesiredAccuracy, LogLevel, PersistMode, NotificationPriority } from '@transistorsoft/capacitor-background-geolocation';

const PREFIX = 'chikaku-';
let wakes = [];
let listening = false;
let readyState = null;

function distM(aLat, aLng, bLat, bLng) {
  const r = (x) => (x * Math.PI) / 180;
  const h = Math.sin(r(bLat - aLat) / 2) ** 2 + Math.cos(r(aLat)) * Math.cos(r(bLat)) * Math.sin(r(bLng - aLng) / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.sqrt(h));
}
// 円の重なりや位置のずれで寝たり起きたりをくり返さないよう、50m の余裕をみる
const nearWake = (lat, lng) => wakes.some((w) => distM(w.latitude, w.longitude, lat, lng) <= w.radius + 50);

function config(o) {
  return {
    reset: true,
    geolocation: {
      desiredAccuracy: DesiredAccuracy.High,
      distanceFilter: 20,               // 20m 動くごとに1回（すれ違いは50m）
      elasticityMultiplier: 2,          // 乗り物の速さの時は、さらに間をあける
      stopTimeout: 5,                   // 5分動かなければ止まったとして休む
      locationAuthorizationRequest: 'Always',
      geofenceInitialTriggerEntry: true,
      locationAuthorizationAlert: {
        titleWhenNotEnabled: '位置情報が「常に」になっていません',
        titleWhenOff: '位置情報サービスがオフです',
        instructions: 'アプリを閉じている間も学内ですれ違うには、設定で位置情報を「常に」にしてください。学外では使いません。',
        cancelButton: 'あとで',
        settingsButton: '設定を開く',
      },
    },
    app: {
      stopOnTerminate: false,           // アプリを閉じても続ける
      startOnBoot: true,                // スマホを再起動しても続ける
      notification: { title: 'ちかく', text: '学内で、すれ違いを記録しています', priority: NotificationPriority.Low },   // Android は記録中この通知が要る
      backgroundPermissionRationale: {
        title: '位置情報を「常に許可」にしてください',
        message: '学内にいる間だけ、アプリを閉じているときも位置情報を使って、すれ違いを記録します。学外では使いません。',
        positiveAction: '設定を開く',
        negativeAction: 'あとで',
      },
    },
    http: {
      url: o.url,
      method: 'POST',
      headers: o.headers || {},
      params: { p_token: o.token },
      rootProperty: 'p_locs',
      autoSync: true,
      batchSync: true,
      maxBatchSize: 20,
    },
    persistence: {
      persistMode: PersistMode.Location,   // 円の出入りの記録は送らない（位置だけ）
      locationTemplate: '{"lat":<%= latitude %>,"lng":<%= longitude %>,"acc":<%= accuracy %>,"at":"<%= timestamp %>","mv":<%= is_moving %>}',
      maxDaysToPersist: 1,
      timestampFormat: 'iso',
    },
    logger: { debug: false, logLevel: LogLevel.Warning },
  };
}

async function sleepIfFar(loc) {
  const c = loc && loc.coords;
  if (!c || c.accuracy >= 100 || nearWake(c.latitude, c.longitude)) return;
  const st = await BackgroundGeolocation.getState();
  if (st.enabled && st.trackingMode === 1) await BackgroundGeolocation.startGeofences();
}

function listen() {
  if (listening) return; listening = true;
  BackgroundGeolocation.onGeofence(async (e) => {
    if (!e.identifier || !e.identifier.startsWith(PREFIX)) return;
    if (e.action === 'ENTER') await BackgroundGeolocation.start();
    else if (e.action === 'EXIT') await sleepIfFar(e.location);
  });
  // 円から出たのに知らせが来なかった時・遠くで誤って起きた時の保険
  BackgroundGeolocation.onLocation((loc) => { sleepIfFar(loc); }, () => {});
}

async function syncGeofences() {
  const want = wakes.map((w) => w.identifier).sort().join();
  const have = (await BackgroundGeolocation.getGeofences()).map((g) => g.identifier).sort().join();
  if (want === have) return;
  await BackgroundGeolocation.removeGeofences();
  await BackgroundGeolocation.addGeofences(wakes);
}

function setWakes(list, radius) {
  wakes = (list || []).map(([lat, lng], i) => ({ identifier: `${PREFIX}${i + 1}`, latitude: lat, longitude: lng, radius: radius || 200, notifyOnEntry: true, notifyOnExit: true }));
}

const pub = (st) => ({ available: true, enabled: !!(st && st.enabled), tracking: !!(st && st.enabled && st.trackingMode === 1) });

window.ChikakuBG = {
  available: () => true,
  // 開くたびに呼ぶ（部品の決まり：ほかの操作の前に ready）。オンにしていれば、そのまま続ける
  async resume(o) {
    setWakes(o.wakes, o.radius); listen();
    readyState = await BackgroundGeolocation.ready(config(o));
    if (readyState.enabled) {
      await syncGeofences();
      // 開いた時に、いまの場所とモードが合っているかを直す（この位置は判断に使うだけで、保存しない）
      try {
        const loc = await BackgroundGeolocation.getCurrentPosition({ samples: 1, timeout: 20, persist: false });
        if (nearWake(loc.coords.latitude, loc.coords.longitude) && readyState.trackingMode === 0) await BackgroundGeolocation.start();
        else await sleepIfFar(loc);
      } catch (e) { /* 位置が取れなかった時はそのまま */ }
    }
    return pub(await BackgroundGeolocation.getState());
  },
  // オンにする（ここで位置の許可を聞かれる）
  async enable(o) {
    setWakes(o.wakes, o.radius); listen();
    readyState = await BackgroundGeolocation.ready(config(o));
    await BackgroundGeolocation.setConfig(config(o));
    await syncGeofences();
    await BackgroundGeolocation.startGeofences();
    return pub(await BackgroundGeolocation.getState());
  },
  // やめる：位置を取るのをやめ、円も端末の中の記録も消す
  async disable() {
    try { await BackgroundGeolocation.stop(); } catch (e) {}
    try { await BackgroundGeolocation.removeGeofences(); } catch (e) {}
    try { await BackgroundGeolocation.destroyLocations(); } catch (e) {}
    return pub(await BackgroundGeolocation.getState());
  },
  // 位置の許可の状態：'always' | 'whenInUse' | 'denied' | 'unknown'
  async permission() {
    try {
      const s = await BackgroundGeolocation.getProviderState();
      return s.status === 3 ? 'always' : s.status === 4 ? 'whenInUse' : (s.status === 1 || s.status === 2) ? 'denied' : 'unknown';
    } catch (e) { return 'unknown'; }
  },
  async state() { try { return pub(await BackgroundGeolocation.getState()); } catch (e) { return { available: true, enabled: false, tracking: false }; } },
};
window.dispatchEvent(new Event('chikakubg'));
