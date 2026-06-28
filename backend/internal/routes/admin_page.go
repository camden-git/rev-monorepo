package routes

// TODO: this sucks
const adminTilesPage = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Rev - Tile Editor</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
<style>
  :root {
    --bg: #16161a;
    --panel: #1f2128;
    --panel-2: #272a33;
    --border: #343845;
    --text: #e6e8ee;
    --muted: #9aa0ad;
    --accent: #5b8cff;
    --danger: #ff5b6e;
    --ok: #36c692;
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; margin: 0; }
  body {
    font: 14px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    color: var(--text); background: var(--bg);
  }
  #map { position: absolute; inset: 0; z-index: 0; background: #0d0d10; }
  .panel {
    position: absolute; z-index: 1000; background: var(--panel);
    border: 1px solid var(--border); border-radius: 10px;
    box-shadow: 0 8px 30px rgba(0,0,0,.45);
  }
  #topbar {
    top: 12px; left: 12px; right: 12px; display: flex; align-items: center;
    gap: 14px; padding: 10px 14px;
  }
  #topbar h1 { font-size: 15px; margin: 0; font-weight: 650; letter-spacing: .2px; }
  #topbar .sep { flex: 1; }
  .status { color: var(--muted); font-size: 12.5px; }
  .status b { color: var(--text); font-weight: 600; }
  .pill {
    display: inline-flex; align-items: center; gap: 6px; padding: 5px 9px;
    border: 1px solid var(--border); border-radius: 8px; background: var(--panel-2);
    color: var(--text); cursor: pointer; font-size: 12.5px; user-select: none;
  }
  .pill:hover { border-color: var(--accent); }
  .pill input { accent-color: var(--accent); margin: 0; }
  button.btn {
    border: 1px solid var(--border); background: var(--panel-2); color: var(--text);
    padding: 6px 12px; border-radius: 8px; cursor: pointer; font-size: 13px;
  }
  button.btn:hover { border-color: var(--accent); }
  button.btn.danger { border-color: transparent; background: var(--danger); color: #fff; font-weight: 600; }
  button.btn.danger:hover { filter: brightness(1.08); }
  #legend {
    bottom: 12px; left: 12px; max-width: 260px; padding: 10px 12px;
    max-height: 40vh; overflow: auto;
  }
  #legend h2 { font-size: 12px; text-transform: uppercase; letter-spacing: .6px; color: var(--muted); margin: 0 0 8px; }
  .legend-row { display: flex; align-items: center; gap: 8px; padding: 3px 0; font-size: 12.5px; }
  .swatch { width: 12px; height: 12px; border-radius: 3px; flex: none; border: 1px solid rgba(255,255,255,.2); }
  .legend-row .count { color: var(--muted); margin-left: auto; }
  /* popup */
  .leaflet-popup-content-wrapper { background: var(--panel); color: var(--text); border: 1px solid var(--border); border-radius: 10px; }
  .leaflet-popup-tip { background: var(--panel); border: 1px solid var(--border); }
  .leaflet-popup-content { margin: 12px 14px; min-width: 180px; }
  .tip-title { font-weight: 650; font-size: 14px; margin-bottom: 6px; display: flex; align-items: center; gap: 7px; }
  .tip-row { color: var(--muted); font-size: 12.5px; display: flex; justify-content: space-between; gap: 14px; }
  .tip-row span:last-child { color: var(--text); font-variant-numeric: tabular-nums; }
  .tip-actions { margin-top: 10px; }
  .tip-actions button { width: 100%; }
  /* auth overlay */
  #auth {
    position: absolute; inset: 0; z-index: 2000; display: none;
    align-items: center; justify-content: center; background: rgba(10,10,14,.78); backdrop-filter: blur(3px);
  }
  #auth.show { display: flex; }
  #auth .card { width: 340px; padding: 22px; }
  #auth h2 { margin: 0 0 4px; font-size: 17px; }
  #auth p { margin: 0 0 16px; color: var(--muted); font-size: 13px; }
  #auth label { display: block; font-size: 12px; color: var(--muted); margin: 12px 0 5px; }
  #auth input {
    width: 100%; padding: 9px 11px; border-radius: 8px; border: 1px solid var(--border);
    background: var(--bg); color: var(--text); font-size: 14px;
  }
  #auth button { margin-top: 18px; width: 100%; background: var(--accent); color: #fff; border: none; padding: 10px; border-radius: 8px; font-size: 14px; font-weight: 600; cursor: pointer; }
  #auth .err { color: var(--danger); font-size: 12.5px; margin-top: 12px; min-height: 16px; }
  #toast {
    position: absolute; bottom: 18px; left: 50%; transform: translateX(-50%);
    z-index: 1500; background: var(--panel-2); border: 1px solid var(--border);
    padding: 9px 16px; border-radius: 999px; font-size: 13px; opacity: 0;
    transition: opacity .2s, transform .2s; pointer-events: none;
  }
  #toast.show { opacity: 1; transform: translateX(-50%) translateY(-4px); }
  #toast.ok { border-color: var(--ok); }
  #toast.bad { border-color: var(--danger); }
  a { color: var(--accent); }
</style>
</head>
<body>
<div id="map"></div>

<div id="topbar" class="panel">
  <h1>Rev · Tile Editor</h1>
  <span class="status" id="status">Loading…</span>
  <span class="sep"></span>
  <label class="pill" title="When on, a single click removes the tile immediately (no popup).">
    <input type="checkbox" id="quick" /> Quick unclaim
  </label>
  <button class="btn" id="refresh">Refresh</button>
</div>

<div id="legend" class="panel">
  <h2>Owners in view</h2>
  <div id="legend-body"><div class="status">—</div></div>
</div>

<div id="toast"></div>

<div id="auth">
  <div class="card panel">
    <h2>Superuser sign-in</h2>
    <p>No active admin session found. Sign in, or open the <a href="/_/" target="_blank">admin dashboard</a> first.</p>
    <label>Email</label>
    <input id="auth-email" type="email" autocomplete="username" />
    <label>Password</label>
    <input id="auth-pass" type="password" autocomplete="current-password" />
    <button id="auth-go">Sign in</button>
    <div class="err" id="auth-err"></div>
  </div>
</div>

<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
(function () {
  "use strict";

  function readToken() {
    try {
      var raw = localStorage.getItem("pb_auth");
      if (!raw) return "";
      var parsed = JSON.parse(raw);
      return (parsed && parsed.token) || "";
    } catch (e) { return ""; }
  }
  var token = readToken();

  function authHeaders() {
    return token ? { "Authorization": token } : {};
  }

  var authEl = document.getElementById("auth");
  function showAuth(msg) {
    authEl.classList.add("show");
    if (msg) document.getElementById("auth-err").textContent = msg;
  }
  function hideAuth() { authEl.classList.remove("show"); }

  document.getElementById("auth-go").addEventListener("click", async function () {
    var email = document.getElementById("auth-email").value.trim();
    var pass = document.getElementById("auth-pass").value;
    document.getElementById("auth-err").textContent = "";
    try {
      var res = await fetch("/api/collections/_superusers/auth-with-password", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ identity: email, password: pass })
      });
      if (!res.ok) throw new Error("Invalid credentials");
      var data = await res.json();
      token = data.token;
      localStorage.setItem("pb_auth", JSON.stringify({ token: data.token, record: data.record || data.admin || null }));
      hideAuth();
      init();
    } catch (e) {
      document.getElementById("auth-err").textContent = e.message || "Sign-in failed";
    }
  });

  var map = L.map("map", { zoomControl: true, worldCopyJump: true }).setView([39.5, -98.35], 4);
  L.tileLayer("https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png", {
    attribution: "&copy; OpenStreetMap &copy; CARTO", subdomains: "abcd", maxZoom: 20
  }).addTo(map);

  var layerGroup = L.layerGroup().addTo(map);
  var tilesByH3 = {};       // h3 -> { layer, data }
  var didInitialFit = false;
  var statusEl = document.getElementById("status");
  var legendBody = document.getElementById("legend-body");

  function toast(msg, kind) {
    var t = document.getElementById("toast");
    t.textContent = msg;
    t.className = "show " + (kind || "");
    clearTimeout(toast._t);
    toast._t = setTimeout(function () { t.className = ""; }, 2400);
  }

  function fmt(n) { return (Math.round(n * 100) / 100).toLocaleString(); }

  function contrast(hex) {
    if (!hex) return "#fff";
    var c = hex.replace("#", "");
    if (c.length === 3) c = c[0]+c[0]+c[1]+c[1]+c[2]+c[2];
    var r = parseInt(c.substr(0,2),16), g = parseInt(c.substr(2,2),16), b = parseInt(c.substr(4,2),16);
    return (r*0.299 + g*0.587 + b*0.114) > 150 ? "#16161a" : "#fff";
  }

  function popupHTML(d) {
    var color = d.owner_color || "#888888";
    var name = d.owner_name || (d.owner ? d.owner : "Unowned");
    return '<div class="tip-title"><span class="swatch" style="background:'+color+'"></span>'+escapeHtml(name)+(d.is_home?' · 🏠 home':'')+'</div>'
      + '<div class="tip-row"><span>Claim score</span><span>'+fmt(d.claim_score)+'</span></div>'
      + '<div class="tip-row"><span>Effective</span><span>'+fmt(d.effective_score)+'</span></div>'
      + '<div class="tip-row"><span>Captures</span><span>'+d.captures+'</span></div>'
      + '<div class="tip-row"><span>H3</span><span style="font-size:11px">'+d.h3+'</span></div>'
      + '<div class="tip-actions"><button class="btn danger" data-unclaim="'+d.h3+'">Unclaim tile</button></div>';
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c];
    });
  }

  function drawTile(d) {
    var color = d.owner_color || "#888888";
    var latlngs = d.boundary.map(function (p) { return [p[0], p[1]]; });
    var poly = L.polygon(latlngs, {
      color: d.is_home ? "#ffffff" : color,
      weight: d.is_home ? 2 : 1,
      opacity: d.is_home ? 0.9 : 0.6,
      dashArray: d.is_home ? "4 3" : null,
      fillColor: color,
      fillOpacity: 0.42
    });
    poly.on("click", function (ev) {
      if (document.getElementById("quick").checked) {
        L.DomEvent.stop(ev);
        unclaim([d.h3]);
        return;
      }
      poly.bindPopup(popupHTML(d)).openPopup();
    });
    poly.addTo(layerGroup);
    tilesByH3[d.h3] = { layer: poly, data: d };
  }

  // wire up unclaim buttons inside popups (event delegation)
  document.addEventListener("click", function (e) {
    var btn = e.target.closest("[data-unclaim]");
    if (btn) unclaim([btn.getAttribute("data-unclaim")]);
  });

  function renderLegend() {
    var counts = {};
    Object.keys(tilesByH3).forEach(function (h3) {
      var d = tilesByH3[h3].data;
      var key = d.owner || "unowned";
      if (!counts[key]) counts[key] = { name: d.owner_name || (d.owner ? "(unknown)" : "Unowned"), color: d.owner_color || "#888888", n: 0 };
      counts[key].n++;
    });
    var rows = Object.keys(counts).map(function (k) { return counts[k]; }).sort(function (a, b) { return b.n - a.n; });
    if (!rows.length) { legendBody.innerHTML = '<div class="status">No tiles in view</div>'; return; }
    legendBody.innerHTML = rows.map(function (r) {
      return '<div class="legend-row"><span class="swatch" style="background:'+r.color+'"></span>'+escapeHtml(r.name)+'<span class="count">'+r.n+'</span></div>';
    }).join("");
  }

  var fetchSeq = 0;
  async function loadViewport(fitAfter) {
    var b = fitAfter ? L.latLngBounds([[-85, -180], [85, 180]]) : map.getBounds();
    var qs = "min_lat="+b.getSouth()+"&min_lng="+b.getWest()+"&max_lat="+b.getNorth()+"&max_lng="+b.getEast();
    var mySeq = ++fetchSeq;
    statusEl.textContent = "Loading…";
    try {
      var res = await fetch("/api/rev/admin/tiles?" + qs, { headers: authHeaders() });
      if (res.status === 401 || res.status === 403) { showAuth("Session expired — sign in again."); return; }
      if (!res.ok) throw new Error("HTTP " + res.status);
      var data = await res.json();
      if (mySeq !== fetchSeq) return; // a newer request superseded this one
      layerGroup.clearLayers();
      tilesByH3 = {};
      data.items.forEach(drawTile);
      renderLegend();
      statusEl.innerHTML = "<b>" + data.items.length + "</b> tiles in view" + (data.truncated ? " · ⚠ truncated, zoom in" : "");
      if (fitAfter && data.items.length && !didInitialFit) {
        didInitialFit = true;
        var all = [];
        data.items.forEach(function (d) { d.boundary.forEach(function (p) { all.push(p); }); });
        if (all.length) map.fitBounds(L.latLngBounds(all).pad(0.2));
      }
    } catch (e) {
      statusEl.textContent = "Load failed: " + e.message;
    }
  }

  async function unclaim(h3s) {
    if (!h3s.length) return;
    var label = h3s.length === 1 ? "this tile" : h3s.length + " tiles";
    if (!document.getElementById("quick").checked || h3s.length > 1) {
      if (!confirm("Unclaim " + label + "? This returns " + (h3s.length === 1 ? "it" : "them") + " to neutral.")) return;
    }
    try {
      var res = await fetch("/api/rev/admin/tiles/unclaim", {
        method: "POST",
        headers: Object.assign({ "Content-Type": "application/json" }, authHeaders()),
        body: JSON.stringify({ h3s: h3s })
      });
      if (res.status === 401 || res.status === 403) { showAuth("Session expired — sign in again."); return; }
      if (!res.ok) throw new Error("HTTP " + res.status);
      var data = await res.json();
      h3s.forEach(function (h3) {
        if (tilesByH3[h3]) { layerGroup.removeLayer(tilesByH3[h3].layer); delete tilesByH3[h3]; }
      });
      map.closePopup();
      renderLegend();
      statusEl.innerHTML = "<b>" + Object.keys(tilesByH3).length + "</b> tiles in view";
      toast("Unclaimed " + data.removed + " tile" + (data.removed === 1 ? "" : "s"), "ok");
    } catch (e) {
      toast("Unclaim failed: " + e.message, "bad");
    }
  }

  var moveTimer;
  function onMove() {
    clearTimeout(moveTimer);
    moveTimer = setTimeout(function () { loadViewport(false); }, 250);
  }

  document.getElementById("refresh").addEventListener("click", function () { loadViewport(false); });

  function init() {
    map.on("moveend", onMove);
    loadViewport(true);
  }

  if (token) init(); else showAuth();
})();
</script>
</body>
</html>`
