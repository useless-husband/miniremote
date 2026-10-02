#!/bin/bash
# 產生 pro 桌面的「選擇電腦.html」+ 雙擊即開的「MiniRemote.app」
# 電腦清單:launcher-peers.json(可自己改);--refresh 會從 Tailscale 裝置清單重抓
cd "$(dirname "$0")"
OUT="$HOME/MiniRemote/選擇電腦.html"
LIST=launcher-peers.json
[ "$1" = "--refresh" ] && rm -f "$LIST"
if [ ! -f "$LIST" ]; then
  TSBIN=$(command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale)
  "$TSBIN" status --json 2>/dev/null | python3 -c '
import sys,json,datetime
d=json.load(sys.stdin); out=[]
now=datetime.datetime.now(datetime.timezone.utc)
for p in d.get("Peer",{}).values():
    exp=p.get("KeyExpiry","")
    try:
        if exp and datetime.datetime.fromisoformat(exp.replace("Z","+00:00")) < now: continue
    except Exception: pass
    if p.get("OS") in ("macOS","windows"):
        out.append({"name":{"macOS":"Mac mini","windows":"Windows"}[p["OS"]],"url":"https://%s/"%p["DNSName"].rstrip("."),"os":p["OS"]})
json.dump(out,open("'"$LIST"'","w"),ensure_ascii=False,indent=2); print("已從 Tailscale 產生",len(out),"台")' || echo '[]' > "$LIST"
fi
python3 - "$LIST" "$OUT" <<'PY'
import json,sys
peers=json.load(open(sys.argv[1]))
defaults=json.dumps([{"name":p["name"],"url":p["url"],"os":p.get("os","")} for p in peers],ensure_ascii=False)
html='''<!DOCTYPE html><html lang="zh-Hant"><head><meta charset="utf-8"><title>選擇電腦</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{color-scheme:dark}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#0b0d10;color:#e6e6e6;font:15px -apple-system,"PingFang TC",system-ui,sans-serif}
.wrap{text-align:center;padding:32px;max-width:900px;width:100%}
h1{font-weight:600;margin:0 0 6px;font-size:28px} .sub{color:#9aa4b2;margin-bottom:26px}
.grid{display:flex;gap:22px;flex-wrap:wrap;justify-content:center}
.card{position:relative;display:block;width:250px;padding:28px 20px 22px;background:#161a20;border:1px solid #2a3038;border-radius:18px;text-decoration:none;color:inherit;transition:transform .12s,border-color .12s,box-shadow .12s;cursor:pointer}
.card:hover{transform:translateY(-3px);border-color:#2f6fed;box-shadow:0 10px 30px rgba(47,111,237,.15)}
.card.last{border-color:#3a4a6a} .card.last::after{content:"上次用的";position:absolute;top:10px;right:12px;font-size:11px;color:#7fb0ff}
.ic{font-size:48px} .nm{font-size:21px;font-weight:600;margin-top:8px} .url{color:#6b7684;font-size:12px;margin-top:4px;word-break:break-all}
.st{margin-top:14px;font-size:13px;color:#9aa4b2} .dot{display:inline-block;width:9px;height:9px;border-radius:50%;background:#666;margin-right:6px;vertical-align:middle}
.on .dot{background:#3ddc84} .off .dot{background:#ff6b6b} .chk .dot{background:#f5b642}
.key{display:inline-block;margin-top:10px;font-size:11px;color:#6b7684;border:1px solid #2a3038;border-radius:5px;padding:1px 7px}
.foot{margin-top:26px;color:#6b7684;font-size:12px;line-height:1.7}
.foot button{background:#232a33;border:1px solid #2a3038;color:#cfd6e0;border-radius:7px;padding:5px 11px;cursor:pointer;margin:0 4px;font-size:12px}
.foot button:hover{background:#2c3540}
#editor{display:none;margin-top:18px;text-align:left;background:#161a20;border:1px solid #2a3038;border-radius:12px;padding:14px}
#editor textarea{width:100%;box-sizing:border-box;height:150px;background:#0f1216;color:#e6e6e6;border:1px solid #2a3038;border-radius:8px;padding:8px;font:13px Menlo,monospace}
#editor .hint{color:#9aa4b2;font-size:12px;margin:6px 0}
</style></head><body><div class="wrap">
<h1>MiniRemote</h1><div class="sub">要連到哪一台?(也可以按鍵盤 1、2)</div>
<div class="grid" id="grid"></div>
<div class="foot">
  綠燈 = 那台開著而且連得到;紅燈 = 睡著、關機、或 Tailscale 沒連。都紅燈先看 pro 右上角 Tailscale 是否連線。<br>
  <button id="recheck">重新檢查</button><button id="edit">編輯電腦清單</button><button id="reset">還原預設清單</button>
</div>
<div id="editor">
  <div class="hint">一行一台,格式:<b>名稱 | 網址</b>(網址是 mini 或 Windows 上 status 印出的 https 網址)</div>
  <textarea id="ta"></textarea>
  <div class="hint">存檔後名單只存在這台瀏覽器裡。<button id="save">儲存</button></div>
</div>
</div>
<script>
const DEFAULTS = ''' + defaults + ''';
const $ = s => document.querySelector(s);
function load() { try { const v = JSON.parse(localStorage.getItem('peers') || 'null'); if (Array.isArray(v) && v.length) return v; } catch {} return DEFAULTS; }
function save(list) { try { localStorage.setItem('peers', JSON.stringify(list)); } catch {} }
function lastUsed() { try { return localStorage.getItem('last') || ''; } catch { return ''; } }
function render() {
  const list = load(), last = lastUsed(), grid = $('#grid'); grid.innerHTML = '';
  list.forEach((p, i) => {
    const a = document.createElement('a'); a.className = 'card' + (p.url === last ? ' last' : ''); a.href = p.url; a.dataset.url = p.url;
    const icon = /mini|mac/i.test(p.name + (p.os||'')) && !/windows/i.test(p.os||'') ? '🖥️' : '🪟';
    a.innerHTML = `<div class="ic">${icon}</div><div class="nm">${p.name}</div><div class="url">${p.url.replace(/^https?:\\/\\//,'').replace(/\\/$/,'')}</div><div class="st chk"><span class="dot"></span><span class="t">檢查中…</span></div><span class="key">${i+1}</span>`;
    a.onclick = () => { try { localStorage.setItem('last', p.url); } catch {} };
    grid.appendChild(a);
  });
  check();
}
async function check() {
  document.querySelectorAll('.card').forEach(async c => {
    const st = c.querySelector('.st'), t = c.querySelector('.t'); st.className = 'st chk'; t.textContent = '檢查中…';
    try {
      const ctl = new AbortController(); setTimeout(() => ctl.abort(), 6000);
      const r = await fetch(c.dataset.url + 'health', { signal: ctl.signal, cache: 'no-store' });
      if (r.ok) { st.className = 'st on'; t.textContent = '在線,點一下連線'; return; }
      throw 0;
    } catch { st.className = 'st off'; t.textContent = '連不到(睡著、關機或 Tailscale 沒連)'; }
  });
}
$('#recheck').onclick = check;
$('#edit').onclick = () => { const e = $('#editor'); e.style.display = e.style.display === 'block' ? 'none' : 'block'; $('#ta').value = load().map(p => `${p.name} | ${p.url}`).join('\\n'); };
$('#save').onclick = () => { const list = $('#ta').value.split('\\n').map(l => l.split('|').map(s => s.trim())).filter(a => a.length >= 2 && a[1]).map(a => ({ name: a[0], url: a[1].endsWith('/') ? a[1] : a[1] + '/' })); if (list.length) { save(list); $('#editor').style.display = 'none'; render(); } };
$('#reset').onclick = () => { try { localStorage.removeItem('peers'); } catch {} render(); };
window.addEventListener('keydown', e => { const n = parseInt(e.key); const cards = document.querySelectorAll('.card'); if (n >= 1 && n <= cards.length) cards[n-1].click(); });
render();
</script></body></html>'''
open(sys.argv[2],'w').write(html)
print("已寫入", sys.argv[2], "共", len(peers), "台")
PY
# 雙擊即開的小 App(用 Chrome 開啟選擇電腦頁)
APP="$HOME/Desktop/MiniRemote.app"
rm -rf "$APP"
osacompile -o "$APP" -e 'do shell script "open -a \"Safari\" " & quoted form of (POSIX path of (path to home folder) & "MiniRemote/選擇電腦.html")' 2>/dev/null && echo "已建立 $APP"
