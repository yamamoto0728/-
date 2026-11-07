/* ちかく：閉じていても学内ですれ違う（2026-11-06）。iPhone は Apple の位置の仕組みで動く（アプリの中の ChikakuLocation.swift）。
   前の tama/bgloc.js（Transistorsoft）は、ストアの版ではライセンスが要るため、iPhone では使わない（Android は今のまま tama/bgloc.js）。
   画面側の窓口（window.ChikakuBG）は前と同じ：resume・enable・disable・permission・state */
(function(){
  var C=window.Capacitor; if(!C)return;
  var P=C.registerPlugin?C.registerPlugin('ChikakuLocation'):(C.Plugins&&C.Plugins.ChikakuLocation);
  if(!P)return;
  var cfg=function(o){ o=o||{}; return {url:o.url,headers:o.headers||{},token:o.token,wakes:o.wakes||[],radius:o.radius||200}; };
  var off={available:true,enabled:false,tracking:false};
  window.ChikakuBG={
    available:function(){ return true; },
    resume:function(o){ return P.resume(cfg(o)); },      // 開くたびに呼ぶ。オンにしていれば、そのまま続ける
    enable:function(o){ return P.enable(cfg(o)); },      // オンにする（ここで位置の許可を聞かれる）
    disable:function(){ return P.disable(); },           // やめる：位置を取るのをやめ、円も端末の中の記録も消す
    permission:function(){ return P.permission().then(function(r){ return (r&&r.status)||'unknown'; },function(){ return 'unknown'; }); },   // 'always' | 'whenInUse' | 'denied' | 'unknown'
    state:function(){ return P.state().catch(function(){ return off; }); }
  };
  window.dispatchEvent(new Event('chikakubg'));
})();
