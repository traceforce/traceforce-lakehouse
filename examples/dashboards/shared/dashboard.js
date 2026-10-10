// Shared helpers for the TraceForce lakehouse dashboards: formatting, the tooltip, charts, tables and
// fetching from serve.mjs. A classic script (not a module) so pages also open as files, in sample mode.
window.Dash = (() => {
  "use strict";

  const DAY = 86400000;
  // Served by serve.mjs, a page queries the lake. Opened as a file, there is no server: sample data.
  const isSample = location.protocol === "file:";
  let rerender = () => {};

  // Display names and fixed color slots follow the entity, never its rank.
  const AGENTS = {
    claude_code:    { name: "Claude Code",    slot: 1 },
    cursor:         { name: "Cursor",         slot: 2 },
    claude:         { name: "Claude",         slot: 3 },
    github_copilot: { name: "GitHub Copilot", slot: 4 },
    chatgpt_codex:  { name: "ChatGPT Codex",  slot: 5 },
  };
  const agentColor = a => AGENTS[a] && AGENTS[a].slot ? `var(--s${AGENTS[a].slot})` : "var(--other)";
  const agentName = a => (AGENTS[a] ? AGENTS[a].name : a);

  // Agents beyond the known five get the next free color slots; the order follows the slots.
  function agentOrderFor(seen) {
    const extra = [...new Set(seen)].filter(a => !AGENTS[a]).sort();
    const used = Object.values(AGENTS).filter(x => x.slot).length;
    extra.forEach((a, i) => {
      AGENTS[a] = { name: a.replace(/_/g, " ").replace(/\b\w/g, c => c.toUpperCase()), slot: used + i < 8 ? used + i + 1 : null };
    });
    return Object.keys(AGENTS).filter(a => seen.includes(a)).sort((x, y) => (AGENTS[x].slot || 99) - (AGENTS[y].slot || 99));
  }

  // ---------- formatting ----------
  const nf = new Intl.NumberFormat("en-US");
  function compact(n) {
    const a = Math.abs(n);
    if (a >= 1e9) return trim(n / 1e9) + "B";
    if (a >= 1e6) return trim(n / 1e6) + "M";
    if (a >= 1e3) return trim(n / 1e3) + "K";
    return nf.format(Math.round(n));
  }
  const trim = v => (Math.abs(v) >= 100 ? Math.round(v).toString() : v.toFixed(1).replace(/\.0$/, ""));
  function usd(n, exact) {
    if (n == null) return "—";
    if (!exact && Math.abs(n) >= 10000) return "$" + compact(n);
    return "$" + n.toLocaleString("en-US", { minimumFractionDigits: n < 100 ? 2 : 0, maximumFractionDigits: n < 100 ? 2 : 0 });
  }
  const num = n => (n == null ? "—" : compact(n));
  const numExact = n => (n == null ? "—" : nf.format(Math.round(n)));
  const share = n => (n > 0.99 && n < 1 ? ">99%" : Math.round(n * 100) + "%");
  const parseDay = s => Date.UTC(+s.slice(0, 4), +s.slice(5, 7) - 1, +s.slice(8, 10));
  const fmtDay = t => new Date(t).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
  const isoDay = t => new Date(t).toISOString().slice(0, 10);

  // Sum that keeps "not reported" (all nulls) distinct from 0.
  function nsum(rows, k) {
    let s = null;
    for (const r of rows) if (r[k] != null) s = (s || 0) + r[k];
    return s;
  }

  const tsParse = s => Date.parse(s.slice(0, 19).replace(" ", "T") + "Z");
  const fmtTs = s => new Date(tsParse(s)).toLocaleString("en-US",
    { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hourCycle: "h23", timeZone: "UTC" });
  function fmtDuration(ms) {
    const m = Math.round(ms / 60000);
    if (m < 1) return "<1m";
    if (m < 60) return m + "m";
    const h = Math.floor(m / 60);
    return h < 48 ? `${h}h ${m % 60}m` : `${Math.round(h / 24)}d`;
  }

  // ---------- DOM helpers ----------
  const $ = id => document.getElementById(id);
  const SVGNS = "http://www.w3.org/2000/svg";
  function el(tag, attrs, text) {
    const n = document.createElement(tag);
    for (const k in attrs || {}) n.setAttribute(k, attrs[k]);
    if (text != null) n.textContent = text;
    return n;
  }
  function sv(tag, attrs, text) {
    const n = document.createElementNS(SVGNS, tag);
    for (const k in attrs || {}) n.setAttribute(k, attrs[k]);
    if (text != null) n.textContent = text;
    return n;
  }
  function swatch(color, line) {
    const s = el("span", { class: line ? "key" : "sw" });
    s.style.background = color;
    return s;
  }

  // ---------- tooltip ----------
  const tip = document.body.appendChild(el("div", { class: "tip", role: "status", "aria-live": "polite" }));
  function showTip(evt, title, rows) {
    tip.replaceChildren(el("div", { class: "t" }, title));
    for (const r of rows) {
      const row = el("div", { class: "r" });
      if (r.color) row.append(swatch(r.color, true));
      row.append(el("b", null, r.value), el("span", null, r.label));
      tip.append(row);
    }
    tip.style.display = "block";
    let x, y;
    if (evt.clientX != null && evt.type !== "focus") { x = evt.clientX; y = evt.clientY; }
    else { const b = evt.target.getBoundingClientRect(); x = b.left + b.width / 2; y = b.top; }
    const w = tip.offsetWidth, h = tip.offsetHeight;
    tip.style.left = Math.min(window.innerWidth - w - 8, Math.max(8, x + 12)) + "px";
    tip.style.top = Math.max(8, y - h - 12) + "px";
  }
  const hideTip = () => { tip.style.display = "none"; };

  // ---------- scales ----------
  // Top of a 4-tick axis whose step is a clean number (1, 2, 2.5 or 5 x 10^n).
  function niceMax(v) {
    if (!(v > 0)) return 4;
    const raw = v / 4, p = Math.pow(10, Math.floor(Math.log10(raw)));
    for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= raw) return m * p * 4;
  }
  function xTickIndexes(n, width) {
    const want = Math.max(2, Math.min(n, Math.floor(width / 70)));
    const step = Math.ceil(n / want);
    const idx = [];
    for (let i = n - 1; i >= 0; i -= step) idx.unshift(i);
    return idx;
  }

  function frame(host, height, yMax, yFmt, leftPad) {
    host.replaceChildren();
    const W = host.clientWidth || 600, H = height;
    const m = { t: 8, r: 8, b: 22, l: leftPad || 44 };
    const svg = sv("svg", { width: W, height: H, role: "img" });
    const iw = W - m.l - m.r, ih = H - m.t - m.b;
    const top = niceMax(yMax);
    const y = v => m.t + ih - (v / top) * ih;
    for (let i = 0; i <= 4; i++) {
      const v = (top / 4) * i, yy = Math.round(y(v)) + 0.5;
      svg.append(sv("line", { class: i ? "gridline" : "baseline", x1: m.l, x2: W - m.r, y1: yy, y2: yy }));
      svg.append(sv("text", { x: m.l - 6, y: yy + 4, "text-anchor": "end" }, yFmt(v)));
    }
    host.append(svg);
    return { svg, W, H, m, iw, ih, y };
  }

  // Stacked columns: 4px rounded data-end on the top segment, 2px surface gap between segments.
  function stackedColumns(host, days, series, fmt, fmtExact, emptyText) {
    const totals = days.map((_, i) => series.reduce((s, x) => s + (x.values[i] || 0), 0));
    const max = Math.max(0, ...totals);
    if (!series.length || max === 0) { host.replaceChildren(el("div", { class: "empty" }, emptyText || "Nothing in this selection")); return; }
    const f = frame(host, 240, max, fmt);
    const band = f.iw / days.length;
    const bw = Math.max(2, Math.min(24, band * 0.7));
    days.forEach((d, i) => {
      const cx = f.m.l + band * i + band / 2;
      let base = f.y(0);
      const visible = series.filter(s => s.values[i] > 0);
      visible.forEach((s, j) => {
        const h = f.y(0) - f.y(s.values[i]);
        const gap = j > 0 ? 2 : 0;
        const segH = Math.max(0, h - gap);
        const x0 = cx - bw / 2, y1 = base - gap, y0 = y1 - segH;
        if (segH <= 0) { base -= h; return; }
        const isTop = j === visible.length - 1;
        const r = isTop ? Math.min(4, bw / 2, segH) : 0;
        const p = `M${x0},${y1}V${y0 + r}Q${x0},${y0} ${x0 + r},${y0}H${x0 + bw - r}Q${x0 + bw},${y0} ${x0 + bw},${y0 + r}V${y1}Z`;
        f.svg.append(sv("path", { d: p, fill: s.color }));
        base -= h;
      });
      const hit = sv("rect", { class: "hit", x: f.m.l + band * i, y: f.m.t, width: band, height: f.ih, tabindex: 0,
        "aria-label": `${fmtDay(parseDay(d))}: ${fmtExact(totals[i])}` });
      const rows = () => [{ value: fmtExact(totals[i]), label: "Total" }].concat(
        series.filter(s => s.values[i] > 0).slice().reverse()
          .map(s => ({ color: s.color, value: fmtExact(s.values[i]), label: s.label })));
      hit.addEventListener("pointermove", e => showTip(e, fmtDay(parseDay(d)), rows()));
      hit.addEventListener("focus", e => showTip(e, fmtDay(parseDay(d)), rows()));
      hit.addEventListener("pointerleave", hideTip);
      hit.addEventListener("blur", hideTip);
      f.svg.insertBefore(hit, f.svg.firstChild.nextSibling);
    });
    for (const i of xTickIndexes(days.length, f.iw))
      f.svg.append(sv("text", { x: f.m.l + band * i + band / 2, y: f.H - 6, "text-anchor": "middle" }, fmtDay(parseDay(days[i]))));
  }

  // Lines: 2px, crosshair snapping to the nearest day, one tooltip listing every series.
  function lineChart(host, days, series, fmt, emptyText, label) {
    const max = Math.max(0, ...series.flatMap(s => s.values));
    if (!series.length || max === 0) { host.replaceChildren(el("div", { class: "empty" }, emptyText || "Nothing in this selection")); return; }
    const labelRoom = series.length <= 4 ? 96 : 8;
    const f = frame(host, 220, max, fmt);
    f.iw -= labelRoom;
    const x = i => f.m.l + (days.length === 1 ? f.iw / 2 : (f.iw * i) / (days.length - 1));
    const ends = [];
    for (const s of series) {
      const d = s.values.map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${f.y(v).toFixed(1)}`).join("");
      f.svg.append(sv("path", { d, fill: "none", stroke: s.color, "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round" }));
      const li = days.length - 1;
      ends.push({ s, x: x(li), y: f.y(s.values[li]) });
    }
    for (const e of ends) f.svg.append(sv("circle", { cx: e.x, cy: e.y, r: 4, fill: e.s.color, stroke: "var(--surface)", "stroke-width": 2 }));
    // Direct end-labels only when they don't collide; otherwise the legend carries identity.
    if (labelRoom > 8) {
      const ys = ends.map(e => e.y).sort((a, b) => a - b);
      const clear = ys.every((v, i) => i === 0 || v - ys[i - 1] >= 14);
      if (clear) for (const e of ends) f.svg.append(sv("text", { class: "lbl", x: e.x + 10, y: e.y + 4 }, e.s.label));
    }
    for (const i of xTickIndexes(days.length, f.iw))
      f.svg.append(sv("text", { x: x(i), y: f.H - 6, "text-anchor": "middle" }, fmtDay(parseDay(days[i]))));

    const cross = sv("line", { class: "baseline", y1: f.m.t, y2: f.m.t + f.ih, visibility: "hidden" });
    f.svg.append(cross);
    const overlay = sv("rect", { class: "hit", x: f.m.l, y: f.m.t, width: Math.max(1, f.iw), height: f.ih, tabindex: 0,
      "aria-label": `${label || "Daily values"}; use arrow keys to step through days` });
    overlay.style.fill = "transparent";
    let cur = days.length - 1;
    const show = (e, i) => {
      cur = i;
      cross.setAttribute("x1", x(i)); cross.setAttribute("x2", x(i)); cross.setAttribute("visibility", "visible");
      showTip(e, fmtDay(parseDay(days[i])), series.slice().sort((a, b) => b.values[i] - a.values[i])
        .map(s => ({ color: s.color, value: numExact(s.values[i]), label: s.label })));
    };
    overlay.addEventListener("pointermove", e => {
      const b = f.svg.getBoundingClientRect();
      const px = e.clientX - b.left;
      const i = Math.round(((px - f.m.l) / Math.max(1, f.iw)) * (days.length - 1));
      show(e, Math.max(0, Math.min(days.length - 1, i)));
    });
    overlay.addEventListener("focus", e => show(e, cur));
    overlay.addEventListener("keydown", e => {
      if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
        e.preventDefault();
        show({ target: overlay, type: "focus" }, Math.max(0, Math.min(days.length - 1, cur + (e.key === "ArrowRight" ? 1 : -1))));
      }
    });
    const off = () => { cross.setAttribute("visibility", "hidden"); hideTip(); };
    overlay.addEventListener("pointerleave", off);
    overlay.addEventListener("blur", off);
    f.svg.append(overlay);
  }

  // Horizontal bars, one series: value at the tip, label above the bar.
  function hBars(host, rows, emptyText) {
    host.replaceChildren();
    if (!rows.length) { host.append(el("div", { class: "empty" }, emptyText)); return; }
    const W = host.clientWidth || 300, rowH = 34, H = rows.length * rowH;
    const svg = sv("svg", { width: W, height: H, role: "img" });
    const valRoom = 64, max = Math.max(...rows.map(r => r.value)) || 1;
    rows.forEach((r, i) => {
      const y0 = i * rowH;
      const w = Math.max(2, ((W - valRoom) * r.value) / max);
      svg.append(sv("text", { class: "lbl", x: 0, y: y0 + 12 }, r.label.length > 34 ? r.label.slice(0, 33) + "…" : r.label));
      const bh = 10, by = y0 + 18, rr = Math.min(4, w / 2);
      svg.append(sv("path", { d: `M0,${by}H${w - rr}Q${w},${by} ${w},${by + rr}V${by + bh - rr}Q${w},${by + bh} ${w - rr},${by + bh}H0Z`, fill: "var(--accent)" }));
      svg.append(sv("text", { class: "val", x: w + 6, y: by + 9 }, r.display));
      const hit = sv("rect", { class: r.onClick ? "hit click" : "hit", x: 0, y: y0, width: W, height: rowH, tabindex: 0,
        "aria-label": `${r.label}: ${r.display}`, role: r.onClick ? "button" : "img" });
      if (r.onClick) {
        hit.addEventListener("click", () => { hideTip(); r.onClick(); });
        hit.addEventListener("keydown", e => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); hideTip(); r.onClick(); } });
      }
      hit.addEventListener("pointermove", e => showTip(e, r.label, r.tip));
      hit.addEventListener("focus", e => showTip(e, r.label, r.tip));
      hit.addEventListener("pointerleave", hideTip);
      hit.addEventListener("blur", hideTip);
      svg.insertBefore(hit, svg.firstChild);
    });
    host.append(svg);
  }

  // head: strings, or {label, sort: {active, dir, onSort}} for a sortable column.
  // rows: arrays of cells, or {cells, onClick} for a clickable row. left: indexes of text columns.
  function table(host, head, rows, left) {
    const isLeft = i => i === 0 || (left || []).includes(i);
    const t = el("table");
    const tr = el("tr");
    head.forEach((h, i) => {
      const cls = isLeft(i) ? { class: "l" } : {};
      if (typeof h === "string") { tr.append(el("th", Object.assign({ scope: "col" }, cls), h)); return; }
      const th = el("th", Object.assign({ scope: "col" }, cls));
      const b = el("button", { type: "button" }, h.label);
      if (h.sort.active) {
        b.setAttribute("aria-sort", h.sort.dir < 0 ? "descending" : "ascending");
        b.dataset.arrow = h.sort.dir < 0 ? "↓" : "↑";
      }
      b.addEventListener("click", h.sort.onSort);
      th.append(b); tr.append(th);
    });
    t.append(el("thead"));
    t.tHead.append(tr);
    const tb = el("tbody");
    const trs = [];
    for (const r of rows) {
      const row = el("tr");
      trs.push(row);
      const cells = Array.isArray(r) ? r : r.cells;
      if (r.onClick) {
        row.className = "click"; row.tabIndex = 0;
        row.addEventListener("click", r.onClick);
        row.addEventListener("keydown", e => { if (e.key === "Enter") r.onClick(); });
      }
      cells.forEach((c, i) => {
        const td = el("td");
        if (c && typeof c === "object" && c.node) { td.append(c.node); if (c.wrap) td.classList.add("wrap"); }
        else { td.textContent = c; if (c === "—") td.classList.add("na"); }
        if (isLeft(i)) td.classList.add("l");
        row.append(td);
      });
      tb.append(row);
    }
    t.append(tb);
    host.replaceChildren(t);
    return trs;
  }
  function legend(host, agents) {
    host.replaceChildren(...agents.map(a => {
      const s = el("span"); s.append(swatch(agentColor(a)), document.createTextNode(agentName(a))); return s;
    }));
  }
  function nameCell(a) {
    const s = el("span", { class: "name" }); s.append(swatch(agentColor(a)), document.createTextNode(agentName(a)));
    return { node: s };
  }

  async function api(path, params) {
    const res = await fetch(path + (params ? "?" + new URLSearchParams(params) : ""));
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(body.error || `${res.status} ${res.statusText}`);
    return body;
  }
  // One fetch per key; the page re-renders when it settles. Sample mode answers locally.
  function fetchOnce(cache, key, sample, path, params) {
    let e = cache.get(key);
    if (e) return e;
    if (isSample) e = Object.assign({ status: "ready" }, sample());
    else {
      e = { status: "loading" };
      api(path, params).then(r => Object.assign(e, { status: "ready" }, r),
        err => Object.assign(e, { status: "error", error: err.message })).then(() => rerender());
    }
    cache.set(key, e);
    return e;
  }
  // A loading or failed fetch, shown in place of its panel; a failure can be retried.
  function pending(e, what, cache, key) {
    const n = el("div", { class: "empty" }, e.status === "loading" ? `Loading ${what} from the lake…` : `Couldn't load ${what}: ${e.error}`);
    if (e.status === "error") {
      const b = el("button", { class: "link", type: "button" }, "Retry");
      b.addEventListener("click", ev => { ev.stopPropagation(); cache.delete(key); rerender(); });
      n.append(b);
    }
    return n;
  }

  return {
    DAY, isSample, onUpdate: f => { rerender = f; },
    AGENTS, agentColor, agentName, agentOrderFor,
    nf, compact, usd, num, numExact, share, parseDay, fmtDay, isoDay, nsum, tsParse, fmtTs, fmtDuration,
    $, el, sv, swatch, showTip, hideTip, stackedColumns, lineChart, hBars, table, legend, nameCell,
    api, fetchOnce, pending,
  };
})();
