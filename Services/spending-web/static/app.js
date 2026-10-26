// Spending Analysis, read-only, on the home network (Services/spending-web). The same numbers as MxAcctMGR's
// Reporting ▸ Spending Analysis (SpendingModel.swift's attribution and forward curve, ported here), without the
// controls that change anything, and with a note to John from every section, entry and rule.
"use strict";

const BASE = location.pathname.replace(/\/[^/]*$/, "");   // /s/<key>
const UNASSIGNED = "UNASSIGNED";
const EFFECTS = [
  { id: "inflation", name: "Inflation", color: "var(--inflation)", help: "Prices: last year's spending times the category's CPI change, plus what spending tagged Inflation grew beyond it" },
  { id: "usage", name: "Usage", color: "var(--usage)", help: "More (or less) of the same: family growth, new activities, and spending with no driver assigned" },
  { id: "lifecycle", name: "Lifecycle", color: "var(--lifecycle)", help: "Expected age-related costs: what spending tagged Lifecycle Transition grew beyond inflation" },
  { id: "behavior", name: "Behavior", color: "var(--behavior)", help: "Habits and tastes: what spending tagged Preference Change grew beyond inflation" },
  { id: "oneTime", name: "One-Time", color: "var(--onetime)", help: "Events that won't repeat: what spending tagged One-Time Event grew beyond inflation" },
];
const DRIVERS = {
  inflation: { title: "Inflation", effect: "inflation", help: "The same thing costs more" },
  family_growth: { title: "Family Growth", effect: "usage", help: "More people, more of the same things" },
  new_activity: { title: "New Activity", effect: "usage", help: "Something the family didn't do before" },
  lifecycle: { title: "Lifecycle Transition", effect: "lifecycle", help: "Expected age-related spending: tutors, driving, college" },
  preference: { title: "Preference Change", effect: "behavior", help: "A habit or taste changed" },
  one_time: { title: "One-Time Event", effect: "oneTime", help: "An event that won't repeat" },
};
const DRIVER_COLORS = ["#e67e22", "#2e86de", "#17a2b8", "#8e44ad", "#d6336c", "#16a085", "#a0a0a0"];
const CHILD_COLORS = ["#2e86de", "#e67e22", "#8e44ad", "#16a085", "#d6336c", "#b9770e"];
const TABS = [["attribution", "Attribution"], ["deepdive", "Deep Dive"], ["curve", "Forward Curve"], ["entries", "Entries"],
              ["rules", "Rules"], ["family", "Family & Lifecycle"], ["sources", "Sources"], ["notes", "My Notes"]];
const STALE_DAYS = 14, STALE_CPI_DAYS = 75;

// ---------------------------------------------------------------------------------------------------------- state

const saved = (k, d) => { try { const v = localStorage.getItem("spending." + k); return v === null ? d : JSON.parse(v); } catch { return d; } };
const keep = (k, v) => { try { localStorage.setItem("spending." + k, JSON.stringify(v)); } catch { /* private window */ } };
const thisYear = new Date().getFullYear();
const S = {
  tab: saved("tab", "attribution"), year: saved("year", thisYear), ytd: saved("ytd", true), full: saved("full", true),
  dive: saved("dive", "HEALTHCARE"), stackBy: saved("stackBy", "child"), inflate: saved("inflate", true),
  period: "current", unassignedOnly: false, cat: "", search: "", shown: 200,
  setup: null, data: null, sources: null, notes: [], problem: null, busy: false,
};

// ---------------------------------------------------------------------------------------------------------- format

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
function money(x) {
  x = Math.abs(x) < 0.005 ? 0 : x;
  return x.toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: Math.abs(x) >= 1000 ? 0 : 2, minimumFractionDigits: Math.abs(x) >= 1000 ? 0 : 2 });
}
const money2 = x => x.toLocaleString("en-US", { style: "currency", currency: "USD" });
const pct = (x, d = 0) => (100 * x).toFixed(d) + "%";
const signedPct = (x, d = 1) => (x >= 0 ? "+" : "") + (100 * x).toFixed(d) + "%";
const signedMoney = x => (x >= 0 ? "+" : "") + money(x);
function day(s) { if (!s) return ""; const [y, m, d] = String(s).slice(0, 10).split("-"); return `${m}/${d}/${y}`; }
function when(s) { if (!s) return ""; const d = new Date(s); return isNaN(d) ? String(s) : d.toLocaleString("en-US", { month: "2-digit", day: "2-digit", year: "numeric", hour: "numeric", minute: "2-digit" }); }
function daysAgo(s) { if (!s) return null; const d = new Date(String(s).length === 10 ? s + "T00:00:00" : s); const n = new Date(); n.setHours(0, 0, 0, 0); d.setHours(0, 0, 0, 0); return Math.round((n - d) / 864e5); }
function age(s) { const n = daysAgo(s); if (n === null) return ""; return n === 0 ? "today" : n === 1 ? "yesterday" : n < 0 ? `in ${-n} day${n === -1 ? "" : "s"}` : `${n} days ago`; }
const cls = x => x > 0.5 ? "up" : x < -0.5 ? "down" : "";
const driverTitle = d => DRIVERS[d]?.title ?? "Not assigned";
const catName = code => code === UNASSIGNED || !code ? "Not assigned" : (S.setup?.categories.find(c => c.code === code)?.name ?? code);
const memberName = id => S.setup?.members.find(m => m.id === id)?.name;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// ---------------------------------------------------------------------------------------------------------- data

function periods() {
  const t = new Date(), y = S.year;
  const [m, d] = S.ytd ? [t.getMonth() + 1, t.getDate()] : [12, 31];
  const dayOf = (yy, mm, dd) => `${yy}-${String(mm).padStart(2, "0")}-${String(Math.min(dd, new Date(yy, mm, 0).getDate())).padStart(2, "0")}`;
  return { start: dayOf(y, 1, 1), end: dayOf(y, m, d), priorStart: dayOf(y - 1, 1, 1), priorEnd: dayOf(y - 1, m, d) };
}

async function api(path, init) {
  const r = await fetch(`${BASE}/api/${path}`, init);
  const j = await r.json().catch(() => ({ error: `The page's server answered ${r.status}` }));
  if (!r.ok || j.error) throw new Error(j.error || `The page's server answered ${r.status}`);
  return j;
}

async function load() {
  S.busy = true; render();
  const p = periods(), q = new URLSearchParams(p).toString();
  try {
    const [setup, data, sources] = await Promise.all([api("setup"), api("analysis?" + q), api("sources?" + q)]);
    Object.assign(S, { setup, data, sources, problem: null });
    await loadNotes();
  } catch (e) { S.problem = e.message; }
  S.busy = false; render();
}

async function loadNotes() {
  const author = saved("author", "");
  S.notes = author ? (await api("feedback?author=" + encodeURIComponent(author))).feedback : [];
}

// ---------------------------------------------------------------------------------------------------------- engine
// As SpendingEngine (SpendingModel.swift): change = inflation + usage + lifecycle + behavior + one-time.

const inNow = e => e.date >= S.data.start && e.date <= S.data.end;
const inBefore = e => e.date >= S.data.priorStart && e.date <= S.data.priorEnd;

function partialRegisters() {
  const start = new Date(S.data.priorStart + "T00:00:00"); start.setDate(start.getDate() + 31);
  return S.data.coverage.filter(c => new Date(String(c.first).slice(0, 10) + "T00:00:00") > start);
}

function entries() {
  if (!S.full) return S.data.entries;
  const out = new Set(partialRegisters().map(c => c.source + (c.register ?? "")));
  return S.data.entries.filter(e => !out.has(e.source + (e.register ?? "")));
}

function attribute(list) {
  const rates = Object.fromEntries(S.data.inflation.map(i => [i.category, i]));
  const prior = {}, current = {};
  for (const e of list) {
    const c = e.category ?? UNASSIGNED, d = e.driver ?? "";
    const into = inNow(e) ? current : inBefore(e) ? prior : null;
    if (!into) continue;
    (into[c] ??= {})[d] = (into[c][d] ?? 0) + e.amount;
  }
  const codes = S.setup.categories.map(c => [c.code, c.name]);
  if (prior[UNASSIGNED] || current[UNASSIGNED]) codes.push([UNASSIGNED, "Not assigned"]);
  const rows = [];
  for (const [code, name] of codes) {
    const p = prior[code] ?? {}, c = current[code] ?? {};
    if (!Object.keys(p).length && !Object.keys(c).length) continue;
    const inf = rates[code] ?? rates.OTHER;
    const rate = inf?.rate ?? 0.03;
    const priorTotal = Object.values(p).reduce((a, b) => a + b, 0);
    const effects = { inflation: priorTotal * rate };
    for (const d of new Set([...Object.keys(p), ...Object.keys(c)])) {
      const grew = (c[d] ?? 0) - (p[d] ?? 0) * (1 + rate);
      const eff = DRIVERS[d]?.effect ?? "usage";
      effects[eff] = (effects[eff] ?? 0) + grew;
    }
    rows.push(makeRow(code, name, priorTotal, Object.values(c).reduce((a, b) => a + b, 0), rate, inf?.basis ?? "assumed", effects));
  }
  return rows;
}

function makeRow(code, name, prior, current, rate, basis, effects) {
  const r = { code, name, prior, current, rate, basis, effects, change: current - prior };
  r.growth = prior > 0.005 ? r.change / prior : null;
  r.effect = id => effects[id] ?? 0;
  r.share = id => Math.abs(r.change) > 0.5 ? r.effect(id) / r.change : null;
  r.reading = (() => {
    if (r.change <= 0.5) return r.change < -0.5 ? "Spending fell" : "Unchanged";
    const unavoidable = (r.share("inflation") ?? 0) + (r.share("lifecycle") ?? 0);
    if (unavoidable >= 0.6) return (r.share("lifecycle") ?? 0) > (r.share("inflation") ?? 0) ? "Unavoidable: age-related" : "Unavoidable: prices";
    if ((r.share("behavior") ?? 0) >= 0.5) return "Habit change";
    if ((r.share("oneTime") ?? 0) >= 0.5) return "One-time";
    if ((r.share("usage") ?? 0) >= 0.5) return "More of the same";
    return "Mixed";
  })();
  return r;
}

function total(rows) {
  const effects = {};
  for (const r of rows) for (const [k, v] of Object.entries(r.effects)) effects[k] = (effects[k] ?? 0) + v;
  const prior = rows.reduce((a, r) => a + r.prior, 0);
  return makeRow("TOTAL", "All spending", prior, rows.reduce((a, r) => a + r.current, 0), prior > 0 ? (effects.inflation ?? 0) / prior : 0, "", effects);
}

const children = () => S.setup.members.filter(m => m.relation === "child" && m.active);
function applies(t, ageNow) {
  if (!t.active || ageNow < t.ageFrom || ageNow > t.ageTo) return false;
  return t.everyYears > 1 ? (ageNow - t.ageFrom) % t.everyYears === 0 : true;
}
function forwardCurve(triggers, start, years = 10) {
  const rates = Object.fromEntries(S.data.inflation.map(i => [i.category, i.rate]));
  const out = [];
  for (let y = start; y < start + years; y++) for (const k of children()) {
    const a = y - k.birthYear;
    for (const t of triggers) if (applies(t, a)) {
      const grow = S.inflate && t.kind !== "peak" ? Math.pow(1 + (rates[t.category] ?? 0.03), y - start) : 1;
      out.push({ year: y, member: k.name, age: a, category: t.category, trigger: t.name, kind: t.kind, amount: t.annualCost * grow });
    }
  }
  return out;
}
function waves(points, start, years = 10) {
  const out = [];
  for (let y = start + 1; y < start + years; y++) {
    const now = points.filter(p => p.year === y), before = points.filter(p => p.year === y - 1);
    const sum = l => l.reduce((a, p) => a + p.amount, 0);
    const had = new Set(before.map(p => p.member + "|" + p.trigger));
    out.push({ year: y, total: sum(now), rise: sum(now) - sum(before), starting: now.filter(p => !had.has(p.member + "|" + p.trigger)).map(p => `${p.member}: ${p.trigger}`) });
  }
  return out.filter(w => w.rise > 0).sort((a, b) => b.rise - a.rise);
}
function sums(list) {
  const s = { before: 0, now: 0, count: 0, countBefore: 0 };
  for (const e of list) { if (inNow(e)) { s.now += e.amount; s.count++; } else if (inBefore(e)) { s.before += e.amount; s.countBefore++; } }
  s.change = s.now - s.before;
  return s;
}
const group = (list, key) => list.reduce((m, e) => { const k = key(e); (m[k] ??= []).push(e); return m; }, {});

// ---------------------------------------------------------------------------------------------------------- charts

function niceTicks(lo, hi, n = 5) {
  if (lo === hi) { hi = lo + 1; }
  const span = hi - lo, step0 = span / n, mag = Math.pow(10, Math.floor(Math.log10(step0)));
  const step = [1, 2, 2.5, 5, 10].map(f => f * mag).find(s => span / s <= n) ?? 10 * mag;
  const ticks = [], top = Math.ceil(hi / step - 1e-9) * step;
  for (let v = Math.floor(lo / step) * step; v <= top + 1e-9; v += step) ticks.push(Math.round(v * 100) / 100);
  return ticks;
}
// Charts are drawn at their box's width, so their text stays its size: the page's column less the box's padding,
// or half of it for two boxes side by side (one above the other on a phone).
function widths() {
  const main = Math.min(1180, document.documentElement.clientWidth) - 32;
  const full = Math.max(280, main - 30);
  return { full, half: main >= 690 ? Math.max(280, (main - 14) / 2 - 30) : full };
}
const short = v => Math.abs(v) >= 1000 ? (v / 1000).toLocaleString("en-US", { maximumFractionDigits: 1 }) + "k" : String(Math.round(v));
const tip = t => `<title>${esc(t)}</title>`;

// Vertical bars: each column a stack of segments (negatives stack down), optionally side by side (grouped).
function columns({ cols, height = 240, grouped = false, catAttr = false, width = widths().full }) {
  const W = width, L = 54, B = 34, T = 8, plotW = W - L - 8, plotH = height - B - T;
  let lo = 0, hi = 0;
  for (const c of cols) {
    if (grouped) for (const s of c.segs) { lo = Math.min(lo, s.value); hi = Math.max(hi, s.value); }
    else { let p = 0, n = 0; for (const s of c.segs) s.value >= 0 ? p += s.value : n += s.value; lo = Math.min(lo, n); hi = Math.max(hi, p); }
  }
  const ticks = niceTicks(lo, hi); lo = Math.min(lo, ticks[0]); hi = Math.max(hi, ticks.at(-1));
  const y = v => T + plotH - (v - lo) / (hi - lo || 1) * plotH;
  const band = plotW / Math.max(cols.length, 1), bw = Math.min(56, band * 0.7);
  let svg = `<svg class="chart" viewBox="0 0 ${W} ${height}" role="img">`;
  for (const t of ticks) svg += `<line class="${t === 0 ? "zero" : "grid"}" x1="${L}" x2="${W - 8}" y1="${y(t)}" y2="${y(t)}"/><text x="${L - 6}" y="${y(t) + 4}" text-anchor="end">${short(t)}</text>`;
  cols.forEach((c, i) => {
    const x0 = L + i * band + (band - bw) / 2, attr = catAttr && c.cat ? ` data-cat="${esc(c.cat)}"` : "";
    if (grouped) {
      const w = bw / c.segs.length;
      c.segs.forEach((s, j) => svg += `<rect${attr} x="${x0 + j * w}" width="${w - 1}" y="${Math.min(y(s.value), y(0))}" height="${Math.abs(y(s.value) - y(0))}" fill="${s.color}">${tip(`${c.label} ${s.name}: ${money(s.value)}`)}</rect>`);
    } else {
      let p = 0, n = 0;
      for (const s of c.segs) {
        const from = s.value >= 0 ? p : n, to = from + s.value;
        s.value >= 0 ? p = to : n = to;
        svg += `<rect${attr} x="${x0}" width="${bw}" y="${Math.min(y(from), y(to))}" height="${Math.max(0.5, Math.abs(y(to) - y(from)))}" fill="${s.color}">${tip(`${c.label} · ${s.name}: ${money(s.value)}`)}</rect>`;
      }
    }
    if (c.note) svg += `<text class="label" x="${x0 + bw / 2}" y="${Math.min(y(c.top ?? 0), y(0)) - 4}" text-anchor="middle">${esc(c.note)}</text>`;
    svg += `<text${attr} x="${x0 + bw / 2}" y="${height - B + 16}" text-anchor="middle">${esc(c.label)}</text>`;
  });
  return svg + "</svg>";
}

// Waterfall: bars from one level to the next.
function waterfall(r, W = widths().half) {
  const steps = [{ label: "Earlier", from: 0, to: r.prior, color: "var(--gray)" }];
  let level = r.prior;
  for (const e of EFFECTS) { steps.push({ label: e.name, from: level, to: level + r.effect(e.id), color: e.color }); level += r.effect(e.id); }
  steps.push({ label: "This year", from: 0, to: r.current, color: "var(--gray)" });
  const H = 250, L = 54, B = 30, T = 24, plotW = W - L - 8, plotH = H - B - T;
  const vals = steps.flatMap(s => [s.from, s.to]);
  const ticks = niceTicks(Math.min(0, ...vals), Math.max(...vals));
  const lo = ticks[0], hi = ticks.at(-1), y = v => T + plotH - (v - lo) / (hi - lo || 1) * plotH;
  const band = plotW / steps.length, bw = band * 0.6;
  let svg = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img">`;
  for (const t of ticks) svg += `<line class="${t === 0 ? "zero" : "grid"}" x1="${L}" x2="${W - 8}" y1="${y(t)}" y2="${y(t)}"/><text x="${L - 6}" y="${y(t) + 4}" text-anchor="end">${short(t)}</text>`;
  steps.forEach((s, i) => {
    const x = L + i * band + (band - bw) / 2, d = s.to - s.from, ends = s.label === "Earlier" || s.label === "This year";
    svg += `<rect x="${x}" width="${bw}" y="${Math.min(y(s.from), y(s.to))}" height="${Math.max(1, Math.abs(y(s.to) - y(s.from)))}" fill="${s.color}" opacity="0.85">${tip(`${s.label}: ${ends ? money(s.to) : signedMoney(d)}`)}</rect>`;
    svg += `<text class="label" x="${x + bw / 2}" y="${(d >= 0 ? y(s.to) : y(s.to)) - (d >= 0 ? 4 : -12)}" text-anchor="middle">${ends ? short(s.to) : (d >= 0 ? "+" : "−") + short(Math.abs(d))}</text>`;
    svg += `<text x="${x + bw / 2}" y="${H - 10}" text-anchor="middle">${esc(s.label)}</text>`;
  });
  return svg + "</svg>";
}

// Horizontal bars beside each category: each effect from zero outward (right adds, left takes off).
function effectBars(rows, W = widths().half) {
  const L = 120, R = 10, rowH = 26, H = rows.length * rowH + 30;
  let lo = 0, hi = 0;
  for (const r of rows) { let p = 0, n = 0; for (const e of EFFECTS) { const v = r.effect(e.id); v >= 0 ? p += v : n += v; } lo = Math.min(lo, n); hi = Math.max(hi, p); }
  const ticks = niceTicks(lo, hi); lo = ticks[0]; hi = ticks.at(-1);
  const x = v => L + (v - lo) / (hi - lo || 1) * (W - L - R);
  let svg = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img">`;
  for (const t of ticks) svg += `<line class="${t === 0 ? "zero" : "grid"}" x1="${x(t)}" x2="${x(t)}" y1="4" y2="${H - 24}"/><text x="${x(t)}" y="${H - 8}" text-anchor="middle">${short(t)}</text>`;
  rows.forEach((r, i) => {
    const yy = 6 + i * rowH, cat = ` data-cat="${esc(r.code)}"`;
    svg += `<text${cat} x="${L - 8}" y="${yy + 15}" text-anchor="end">${esc(r.name)}</text>`;
    let p = 0, n = 0;
    for (const e of EFFECTS) {
      const v = r.effect(e.id); if (Math.abs(v) < 0.5) continue;
      const from = v >= 0 ? p : n, to = from + v; v >= 0 ? p = to : n = to;
      svg += `<rect${cat} x="${Math.min(x(from), x(to))}" width="${Math.abs(x(to) - x(from))}" y="${yy + 3}" height="${rowH - 8}" fill="${e.color}">${tip(`${r.name} · ${e.name}: ${signedMoney(v)}`)}</rect>`;
    }
  });
  return svg + "</svg>";
}

function legend(items) { return `<div class="legend">${items.map(([n, c]) => `<span><i style="background:${c}"></i>${esc(n)}</span>`).join("")}</div>`; }

// ---------------------------------------------------------------------------------------------------------- pieces

function box(title, body, { section = title, help = "", extra = "" } = {}) {
  return `<section class="box"><div class="box-head"><h3 title="${esc(help)}">${esc(title)}</h3>${extra}
    <button class="icon" data-action="feedback" data-section="${esc(section)}" title="Send John a note about ${esc(title)}">💬 Note</button></div>${body}</section>`;
}
const tile = (t, v, c = "", help = "", color = "") => `<div class="tile" title="${esc(help)}"><div class="t">${esc(t)}</div><div class="v" style="${color ? "color:" + color : ""}">${v}</div><div class="c">${esc(c)}</div></div>`;

function strip() {
  const o = S.sources; if (!o) return "";
  const used = o.sources.filter(s => s.included);
  const newest = used.map(s => s.spendingLast).filter(d => d && daysAgo(d) >= 0).sort().at(-1);
  const run = n => o.loaders.find(l => l.loader === n);
  const cpi = o.tables.find(t => t.name === "srm.market_series_value")?.newest;
  const stale = daysAgo(newest) > STALE_DAYS || daysAgo(cpi) > STALE_CPI_DAYS;
  const parts = [
    "Sources: " + (used.map(s => s.name).join(", ") || "none") + (used.length < o.sources.length ? ` (${o.sources.length - used.length} left out)` : ""),
    newest && `spending through ${day(newest)} (${age(newest)})`,
    run("card_downloads")?.finishedAt && `cards read ${when(run("card_downloads").finishedAt)}`,
    cpi && `CPI through ${new Date(cpi + "T00:00:00").toLocaleString("en-US", { month: "short", year: "numeric" })}`,
  ].filter(Boolean);
  return `<div class="strip${stale ? " stale" : ""}">${stale ? "⚠︎" : "▤"} ${esc(parts.join(" · "))} <button class="link" data-tab="sources">Sources</button></div>`;
}

function controls() {
  const years = []; for (let y = thisYear; y >= thisYear - 5; y--) years.push(y);
  const d = S.data;
  return `<div class="bar">
    <label>Year <select data-set="year">${years.map(y => `<option value="${y}"${y === S.year ? " selected" : ""}>${y} vs ${y - 1}</option>`).join("")}</select></label>
    <label><input type="checkbox" data-set="ytd"${S.ytd ? " checked" : ""}> Year to date</label>
    <label title="Leave out the registers whose spending starts after the earlier year does"><input type="checkbox" data-set="full"${S.full ? " checked" : ""}> Only registers covering both years</label>
    <span class="spacer"></span>
    ${S.busy ? `<span class="muted">Reading…</span>` : ""}
    ${d ? `<span class="muted">${day(d.start)} – ${day(d.end)} vs ${day(d.priorStart)} – ${day(d.priorEnd)}</span>` : ""}
    <button data-action="reload" title="Read the registers again">↻</button>
  </div>`;
}

const tabsBar = () => `<nav class="tabs">${TABS.map(([id, t]) => `<button class="${S.tab === id ? "on" : ""}" data-tab="${id}">${t}${id === "notes" && unreadReplies() ? ` (${unreadReplies()} new)` : ""}</button>`).join("")}</nav>`;

// ---------------------------------------------------------------------------------------------------------- tabs

function attributionTab() {
  const rows = attribute(entries()), t = total(rows), partial = partialRegisters();
  let h = "";
  if (partial.length) h += `<p class="notice${S.full ? "" : " warn"}">${esc(partial.map(c => `${c.register ?? c.source} starts ${day(c.first)}`).join("; "))}${S.full ? ": left out, as it doesn't cover the earlier year." : ": its earlier-year spending is missing, so its whole spending counts as growth."}</p>`;
  h += `<div class="tiles">${tile("Earlier year", money(t.prior))}${tile("This year", money(t.current))}${tile("Change", money(t.change), t.growth === null ? "" : signedPct(t.growth), "This year less the earlier year", t.change > 0 ? "var(--up)" : "var(--down)")}
    ${["inflation", "lifecycle", "behavior"].map(id => { const e = EFFECTS.find(x => x.id === id); return tile(e.name, money(t.effect(id)), t.share(id) === null ? "" : `${pct(t.share(id))} of the change`, e.help); }).join("")}</div>`;
  if (!rows.length) return h + `<p class="muted">No spending in these periods.</p>`;
  const tr = r => `<tr${r.code === "TOTAL" ? ' class="total"' : ""}>
      <td class="l">${r.code === "TOTAL" ? esc(r.name) : `<button class="link" data-dive="${esc(r.code)}" title="Deep dive into ${esc(r.name)}">${esc(r.name)}</button>`}</td>
      <td>${money(r.prior)}</td><td>${money(r.current)}</td><td class="${cls(r.change)}">${money(r.change)}</td>
      <td>${r.growth === null ? (r.prior === 0 && r.current > 0 ? "new" : "—") : signedPct(r.growth, 0)}</td>
      ${EFFECTS.map(e => `<td title="${money(r.effect(e.id))}">${r.share(e.id) === null ? "—" : pct(r.share(e.id))}</td>`).join("")}
      <td class="muted">${signedPct(r.rate, 1)}${r.code !== "TOTAL" && r.basis !== "CPI" ? "*" : ""}</td><td class="l muted">${esc(r.reading)}</td></tr>`;
  h += box("Key Metrics by Category", `<div class="scroll"><table><tr><th class="l">Category</th><th>Earlier</th><th>This year</th><th>Change</th><th>Growth</th>
      ${EFFECTS.map(e => `<th title="${esc(e.help)}" style="color:${e.color}">${e.name}</th>`).join("")}<th>CPI</th><th class="l">Reading</th></tr>
      ${rows.map(tr).join("")}${tr(t)}</table></div>
      <p class="hint">Contributions are shares of the change. Click a category for its deep dive. CPI is the category's price change between the years (FRED; * assumed where there are no values yet).</p>`,
    { help: "Each category's growth and how much of its change each effect explains" });
  h += `<div class="row">${box("From Last Year to This Year", waterfall(t))}${box("What Changed Each Category", effectBars(rows) + legend(EFFECTS.map(e => [e.name, e.color])), { help: "Click a category for its deep dive" })}</div>`;
  // Both dimensions of this year's dollars.
  const now = entries().filter(inNow), order = S.setup.categories.map(c => c.code).concat([UNASSIGNED]);
  const drv = Object.keys(DRIVERS).concat([""]);
  const cols = order.map(code => {
    const mine = now.filter(e => (e.category ?? UNASSIGNED) === code); if (!mine.length) return null;
    const by = group(mine, e => e.driver ?? "");
    return { label: catName(code), cat: code, segs: drv.filter(d => by[d]).map(d => ({ name: driverTitle(d || null), value: by[d].reduce((a, e) => a + e.amount, 0), color: DRIVER_COLORS[drv.indexOf(d)] })) };
  }).filter(Boolean);
  h += box("This Year by Category and Driver", columns({ cols, catAttr: true }) + legend(drv.map((d, i) => [driverTitle(d || null), DRIVER_COLORS[i]])),
    { help: "Click a category's bar or name for its deep dive" });
  h += box("Inflation by Category", `<div class="scroll"><table><tr><th class="l">Category</th><th>Change</th><th class="l">Basis</th><th class="l">Series</th></tr>
    ${S.data.inflation.map(i => `<tr><td class="l">${esc(catName(i.category))}</td><td>${signedPct(i.rate, 1)}</td><td class="l">${i.basis === "CPI" ? `CPI, ${i.months} months to ${day(i.through)}` : `assumed ${pct(i.assumed, 1)} a year`}</td><td class="l muted">${esc(S.setup.categories.find(c => c.code === i.category)?.cpiName ?? "—")}</td></tr>`).join("")}</table></div>`);
  return h;
}

function diveTab() {
  const all = entries(), rows = attribute(all), code = S.dive, r = rows.find(x => x.code === code), name = catName(code);
  const mine = all.filter(e => (e.category ?? UNASSIGNED) === code);
  const y = S.data.start.slice(0, 4), py = S.data.priorStart.slice(0, 4);
  let h = `<div class="bar"><label>Deep dive into <select data-set="dive">${S.setup.categories.map(c => `<option value="${c.code}"${c.code === code ? " selected" : ""}>${esc(c.name)}</option>`).join("")}<option value="${UNASSIGNED}"${code === UNASSIGNED ? " selected" : ""}>Not assigned</option></select></label>
    ${r ? `<b>${money(r.prior)} in ${py} → ${money(r.current)} in ${y}: ${signedMoney(r.change)}${r.growth === null ? "" : ` (${signedPct(r.growth)})`}</b><span class="muted">${esc(r.reading)}</span>` : ""}
    <span class="spacer"></span><button data-tab="attribution">‹ Attribution</button></div>`;
  if (!r) return h + `<p class="muted">Nothing in ${py} or ${y} is in ${esc(name)}.</p>` + lifecycleBox(code);
  h += `<div class="tiles">${EFFECTS.map(e => tile(e.name, signedMoney(r.effect(e.id)), r.share(e.id) === null ? "" : `${pct(r.share(e.id))} of the change`, e.help, e.color)).join("")}${tile("Prices (CPI)", signedPct(r.rate), r.basis === "CPI" ? (S.setup.categories.find(c => c.code === code)?.cpiName ?? "CPI") : "assumed")}</div>`;
  // Month by month.
  const months = {}; for (const e of mine) { const m = +e.date.slice(5, 7); const k = inNow(e) ? "now" : inBefore(e) ? "before" : null; if (k) (months[m] ??= { now: 0, before: 0 })[k] += e.amount; }
  const cols = Object.keys(months).map(Number).sort((a, b) => a - b).map(m => ({ label: MONTHS[m - 1], segs: [{ name: py, value: months[m].before, color: "var(--gray)" }, { name: y, value: months[m].now, color: "var(--accent)" }] }));
  h += `<div class="row">${box(`${name}: From Last Year to This Year`, waterfall(r), { section: `Deep Dive ${name}: waterfall` })}${box("Month by Month", columns({ cols, grouped: true, width: widths().half }) + legend([[py, "var(--gray)"], [y, "var(--accent)"]]), { section: `Deep Dive ${name}: months` })}</div>`;
  // Drivers.
  const byDriver = group(mine, e => e.driver ?? "");
  h += box("By Driver", `<div class="scroll"><table><tr><th class="l">Driver</th><th>${py}</th><th>${y}</th><th>Change</th><th>Beyond prices</th><th class="l">Counts as</th></tr>
    <tr><td class="l">Prices on ${py}'s spending (${signedPct(r.rate)})</td><td></td><td></td><td></td><td>${money(r.prior * r.rate)}</td><td class="l">Inflation</td></tr>
    ${Object.keys(DRIVERS).concat([""]).filter(d => byDriver[d]).map(d => { const s = sums(byDriver[d]); const eff = EFFECTS.find(e => e.id === (DRIVERS[d]?.effect ?? "usage")); return `<tr><td class="l" title="${esc(DRIVERS[d]?.help ?? "No rule or tag gives it a driver")}">${esc(DRIVERS[d]?.title ?? "No driver yet")}</td><td>${money(s.before)}</td><td>${money(s.now)}</td><td class="${cls(s.change)}">${money(s.change)}</td><td>${money(s.now - s.before * (1 + r.rate))}</td><td class="l">${eff.name}</td></tr>`; }).join("")}
    <tr class="total"><td class="l">Change</td><td>${money(r.prior)}</td><td>${money(r.current)}</td><td>${money(r.change)}</td><td>${money(r.change)}</td><td></td></tr></table></div>`, { section: `Deep Dive ${name}: drivers` });
  // How entries got here.
  const origins = group(mine, e => (e.categoryFrom ?? "none") + "|" + (e.categoryFrom === "expense account" ? e.expenseAccount : e.categoryFrom === "target account" ? e.payee : e.categoryFrom === "entry" ? "Tagged on the entry" : (e.expenseAccount ? e.expenseAccount + " (no rule)" : "No expense account, rule or tag")));
  const ruleText = (kind, label) => { const rr = S.setup.rules.find(x => kind === "expense account" ? x.expenseAccount === label : kind === "target account" ? x.payee === label : false); return rr ? [catName(rr.category), rr.driver && driverTitle(rr.driver), memberName(rr.memberId)].filter(Boolean).join(" · ") : ""; };
  h += box("How Entries Got Here", `<div class="scroll"><table><tr><th class="l">Put here by</th><th class="l">Rule says</th><th>${py}</th><th>${y}</th><th>Change</th><th>Entries</th><th></th></tr>
    ${Object.entries(origins).sort((a, b) => Math.abs(sums(b[1]).now) + Math.abs(sums(b[1]).before) - Math.abs(sums(a[1]).now) - Math.abs(sums(a[1]).before)).map(([k, list]) => {
      const [kind, label] = k.split("|"); const s = sums(list);
      return `<tr><td class="l">${esc(label)}<br><span class="muted">${kind === "none" ? "not assigned" : kind === "entry" ? "entry tags" : kind + " rule"}</span></td><td class="l muted">${esc(ruleText(kind, label))}</td><td>${money(s.before)}</td><td>${money(s.now)}</td><td class="${cls(s.change)}">${money(s.change)}</td><td>${s.countBefore} → ${s.count}</td>
        <td>${kind === "expense account" || kind === "target account" ? `<button class="icon" data-action="feedback" data-kind="rule" data-section="Rule: ${esc(kind)} ${esc(label)}" data-category="${esc(code)}">Suggest a change</button>` : ""}</td></tr>`;
    }).join("")}</table></div>`, { section: `Deep Dive ${name}: how entries got here`, help: "What put each entry in this category: an expense account's rule, a target account's rule, or the entry's own tag" });
  // Where it went.
  const byAccount = group(mine, e => e.expenseAccount ?? "No expense account");
  let w = "";
  for (const a of Object.keys(byAccount).sort((p, q) => sums(byAccount[q]).now - sums(byAccount[p]).now)) {
    const s = sums(byAccount[a]);
    w += `<tr><td class="l"><b>${esc(a)}</b></td><td>${money(s.before)}</td><td>${money(s.now)}</td><td class="${cls(s.change)}">${money(s.change)}</td><td>${s.countBefore} → ${s.count}</td></tr>`;
    const byPayee = group(byAccount[a], e => e.payee ?? e.description ?? "—");
    const payees = Object.keys(byPayee).sort((p, q) => Math.abs(sums(byPayee[q]).change) - Math.abs(sums(byPayee[p]).change));
    for (const p of payees.slice(0, 6)) { const ps = sums(byPayee[p]); w += `<tr><td class="l muted" style="padding-left:22px">${esc(p)}</td><td>${money(ps.before)}</td><td>${money(ps.now)}</td><td class="${cls(ps.change)}">${money(ps.change)}</td><td class="muted">${ps.countBefore} → ${ps.count}</td></tr>`; }
    if (payees.length > 6) { const rest = sums(payees.slice(6).flatMap(p => byPayee[p])); w += `<tr class="muted"><td class="l" style="padding-left:22px">${payees.length - 6} more</td><td>${money(rest.before)}</td><td>${money(rest.now)}</td><td>${money(rest.change)}</td><td>${rest.countBefore} → ${rest.count}</td></tr>`; }
  }
  h += box("Where It Went", `<div class="scroll"><table><tr><th class="l">Expense account / payee</th><th>${py}</th><th>${y}</th><th>Change</th><th>Entries</th></tr>${w}</table></div>`, { section: `Deep Dive ${name}: where it went` });
  const top = mine.filter(inNow).sort((a, b) => b.amount - a.amount).slice(0, 10);
  const byMember = group(mine, e => e.memberId ?? 0);
  h += `<div class="row">${box("Largest This Year", `<div class="scroll"><table>${top.map(e => `<tr><td class="l muted">${day(e.date)}</td><td class="l">${esc(e.payee ?? e.description ?? "—")}</td><td>${money2(e.amount)}</td><td class="l muted">${esc(e.event ?? driverTitle(e.driver))}</td><td>${flag(e)}</td></tr>`).join("")}</table></div>`, { section: `Deep Dive ${name}: largest` })}
    ${box("By Family Member", Object.keys(byMember).every(k => k === "0") ? `<p class="muted">None of it names a family member yet.</p>` : `<table><tr><th class="l">Member</th><th>${py}</th><th>${y}</th><th>Change</th></tr>${Object.keys(byMember).map(k => { const s = sums(byMember[k]); return `<tr><td class="l">${esc(memberName(+k) ?? "No one named")}</td><td>${money(s.before)}</td><td>${money(s.now)}</td><td>${money(s.change)}</td></tr>`; }).join("")}</table>`, { section: `Deep Dive ${name}: members` })}</div>`;
  h += lifecycleBox(code);
  h += entriesBox(mine, `${name} Entries`, true);
  return h;
}

function lifecycleBox(code) {
  const triggers = S.setup.triggers.filter(t => t.category === code && t.active);
  if (!triggers.length) return box("Lifecycle Triggers and What's Coming", `<p class="muted">No lifecycle trigger is in ${esc(catName(code))}.</p>`, { section: `Deep Dive ${catName(code)}: lifecycle` });
  const start = thisYear, pts = forwardCurve(triggers, start), kids = [...new Set(pts.map(p => p.member))];
  const cols = []; for (let yy = start; yy < start + 10; yy++) cols.push({ label: String(yy), segs: kids.map((k, i) => ({ name: k, value: pts.filter(p => p.year === yy && p.member === k).reduce((a, p) => a + p.amount, 0), color: CHILD_COLORS[i % CHILD_COLORS.length] })) });
  return box("Lifecycle Triggers and What's Coming", `<table>${triggers.map(t => `<tr><td class="l">${esc(t.name)}</td><td class="l muted">ages ${ages(t)}</td><td class="l muted">${esc(t.kind)}</td><td>${money(t.annualCost)} a year</td></tr>`).join("")}</table>
    ${children().length ? (pts.length ? columns({ cols, height: 200 }) + legend(kids.map((k, i) => [k, CHILD_COLORS[i % CHILD_COLORS.length]])) : `<p class="muted">None of them applies to the children in the next ten years.</p>`) : `<p class="muted">No children are set up yet.</p>`}`, { section: `Deep Dive ${catName(code)}: lifecycle` });
}
const ages = t => (t.ageFrom === t.ageTo ? `${t.ageFrom}` : `${t.ageFrom}–${t.ageTo}`) + (t.everyYears > 1 ? `, every ${t.everyYears} years` : "");

function flag(e) {
  return `<button class="icon" data-action="feedback" data-kind="entry" data-entry="${esc(e.source)}:${e.entryId}" title="Something's off with this entry? Tell John">⚑</button>`;
}

function entriesBox(list, title, locked) {
  const q = S.search.toLowerCase();
  const rows = list.filter(e => (S.period === "both" || (S.period === "current") === inNow(e))
    && (!S.unassignedOnly || !e.driver) && (locked || !S.cat || (e.category ?? UNASSIGNED) === S.cat)
    && (!q || [e.payee, e.description, e.expenseAccount, e.event, e.register].some(v => (v ?? "").toLowerCase().includes(q))))
    .sort((a, b) => a.date < b.date ? 1 : -1);
  const body = `<div class="bar">
      <select data-set="period"><option value="current"${S.period === "current" ? " selected" : ""}>This year</option><option value="prior"${S.period === "prior" ? " selected" : ""}>Earlier year</option><option value="both"${S.period === "both" ? " selected" : ""}>Both</option></select>
      ${locked ? "" : `<select data-set="cat"><option value="">All categories</option>${S.setup.categories.map(c => `<option value="${c.code}"${S.cat === c.code ? " selected" : ""}>${esc(c.name)}</option>`).join("")}<option value="${UNASSIGNED}"${S.cat === UNASSIGNED ? " selected" : ""}>Not assigned</option></select>`}
      <label><input type="checkbox" data-set="unassignedOnly"${S.unassignedOnly ? " checked" : ""}> No driver yet</label>
      <input type="search" data-set="search" value="${esc(S.search)}" placeholder="Search payee, description, event">
      <span class="spacer"></span><span class="muted">${rows.length.toLocaleString()} entries, ${money(rows.reduce((a, e) => a + e.amount, 0))}</span></div>
    <div class="scroll"><table><tr><th class="l">Date</th><th class="l">From</th><th class="l">Payee</th><th class="l">Expense account</th><th>Amount</th><th class="l">Category</th><th class="l">Driver</th><th class="l">Member</th><th class="l">Event</th><th></th></tr>
    ${rows.slice(0, S.shown).map(e => `<tr><td class="l">${day(e.date)}</td><td class="l muted">${esc(e.register ?? e.source)}</td><td class="l">${esc(e.payee ?? e.description ?? "")}</td><td class="l muted">${esc(e.expenseAccount ?? "")}</td>
      <td>${money2(e.amount)}</td><td class="l" title="${esc(e.categoryFrom ? "From the " + e.categoryFrom : "No rule or tag")}">${esc(catName(e.category))}</td><td class="l" title="${esc(e.driverFrom ? "From the " + e.driverFrom : "No rule or tag: counts as usage")}">${esc(driverTitle(e.driver))}</td>
      <td class="l muted">${esc(memberName(e.memberId) ?? "")}</td><td class="l muted">${esc(e.event ?? "")}</td><td>${flag(e)}</td></tr>`).join("")}</table></div>
    ${rows.length > S.shown ? `<p><button data-action="more">Show ${Math.min(200, rows.length - S.shown)} more</button></p>` : ""}`;
  return box(title, body, { section: title, help: "Every spending dollar: its category and driver and where they came from. ⚑ tells John something about one entry." });
}

function curveTab() {
  if (!children().length) return box("Family Spending Forward Curve", `<p class="muted">No children are set up yet, so there is no forward curve.</p>`);
  const start = thisYear, pts = forwardCurve(S.setup.triggers, start);
  const keys = S.stackBy === "child" ? [...new Set(children().map(k => k.name))] : [...new Set(pts.map(p => p.category))];
  const colors = S.stackBy === "child" ? CHILD_COLORS : ["#2e86de", "#e67e22", "#8e44ad", "#16a085", "#d6336c", "#b9770e", "#17a2b8", "#7f8c8d", "#c0392b", "#2c3e50"];
  const cols = []; for (let y = start; y < start + 10; y++) cols.push({ label: String(y), segs: keys.map((k, i) => ({ name: S.stackBy === "child" ? k : catName(k), value: pts.filter(p => p.year === y && (S.stackBy === "child" ? p.member : p.category) === k).reduce((a, p) => a + p.amount, 0), color: colors[i % colors.length] })) });
  let h = `<div class="bar"><label>Stack by <select data-set="stackBy"><option value="child"${S.stackBy === "child" ? " selected" : ""}>Child</option><option value="category"${S.stackBy === "category" ? " selected" : ""}>Category</option></select></label>
    <label title="Grow each cost by its category's inflation; peak events stay in today's dollars"><input type="checkbox" data-set="inflate"${S.inflate ? " checked" : ""}> Grow with inflation</label></div>`;
  h += box("Family Spending Forward Curve", columns({ cols, height: 280 }) + legend(keys.map((k, i) => [S.stackBy === "child" ? k : catName(k), colors[i % colors.length]])), { help: "Each child's lifecycle costs for the next ten years, stacked" });
  const all = waves(pts, start), soon = all.filter(w => w.year >= start + 3 && w.year <= start + 5);
  const wv = w => `<tr><td class="l"><b>${w.year}</b></td><td class="up">+${money(w.rise)}</td><td class="muted">to ${money(w.total)}</td><td class="l wrap">${esc(w.starting.join("; ") || "more of what's already under way")}</td></tr>`;
  h += box("Waves Ahead", all.length ? `${soon.length ? `<p class="hint">Three to five years out</p><table>${soon.map(wv).join("")}</table>` : ""}<p class="hint">Largest rises in the next ten years</p><table>${all.slice(0, 3).map(wv).join("")}</table>` : `<p class="muted">No year's costs rise over the year before.</p>`);
  const kids = children();
  h += box("Year by Year", `<div class="scroll"><table><tr><th class="l">Year</th>${kids.map(k => `<th>${esc(k.name)}</th>`).join("")}<th>Total</th></tr>
    ${cols.map(c => { const y = +c.label; return `<tr><td class="l">${y}</td>${kids.map(k => { const mine = pts.filter(p => p.year === y && p.member === k.name); return `<td title="${esc(mine.map(p => `${p.trigger}: ${money(p.amount)}`).join("\n"))}">${money(mine.reduce((a, p) => a + p.amount, 0))} (${y - k.birthYear})</td>`; }).join("")}<td><b>${money(pts.filter(p => p.year === y).reduce((a, p) => a + p.amount, 0))}</b></td></tr>`; }).join("")}</table></div>`);
  return h;
}

function rulesTab() {
  const now = entries().filter(inNow);
  const spentBy = key => now.reduce((m, e) => { const k = key(e); if (k != null) m[k] = (m[k] ?? 0) + e.amount; return m; }, {});
  const byAccount = spentBy(e => e.expenseAccountId), byPayee = spentBy(e => e.payeeId);
  const row = (name, spent, r, kind) => `<tr><td class="l">${esc(name)}</td><td>${money(spent ?? 0)}</td><td class="l">${esc(r?.category ? catName(r.category) : kind === "target" ? "Account's" : "None")}</td><td class="l">${esc(r?.driver ? driverTitle(r.driver) : "—")}</td><td class="l muted">${esc(memberName(r?.memberId) ?? "")}</td>
    <td><button class="icon" data-action="feedback" data-kind="rule" data-section="Rule: ${kind === "target" ? "target account" : "expense account"} ${esc(name)}" data-category="${esc(r?.category ?? "")}">Suggest a change</button></td></tr>`;
  const head = `<tr><th class="l">Account</th><th>This year</th><th class="l">Category</th><th class="l">Driver</th><th class="l">Member</th><th></th></tr>`;
  const targets = S.setup.rules.filter(r => r.payeeId);
  return box("Expense Account Rules", `<div class="scroll"><table>${head}${S.setup.expenseAccounts.map(a => row(a.name, byAccount[a.id], S.setup.rules.find(r => r.expenseAccountId === a.id), "expense")).join("")}</table></div>`,
      { help: "The category, driver and member of each expense account's spending. Suggest a change to tell John." })
    + box("Target Account Rules", targets.length ? `<div class="scroll"><table>${head}${targets.map(r => row(r.payee, byPayee[r.payeeId], r, "target")).join("")}</table></div>` : `<p class="muted">No target account has a rule of its own.</p>`,
      { help: "Rules for single payees, overriding their expense account's" });
}

function familyTab() {
  const grade = a => a < 5 ? "Preschool" : a === 5 ? "Kindergarten" : a <= 17 ? `Grade ${a - 5}` : a <= 21 ? `College year ${a - 17}` : "";
  return box("Family", S.setup.members.length ? `<table><tr><th class="l">Name</th><th class="l">Relation</th><th>Born</th><th>Age</th><th class="l">Grade</th></tr>${S.setup.members.map(m => `<tr><td class="l">${esc(m.name)}</td><td class="l">${esc(m.relation)}</td><td>${m.birthMonth ? m.birthMonth + "/" : ""}${m.birthYear}</td><td>${thisYear - m.birthYear}</td><td class="l muted">${m.relation === "child" ? grade(thisYear - m.birthYear) : ""}</td></tr>`).join("")}</table>` : `<p class="muted">No one is set up yet.</p>`)
    + box("Lifecycle Triggers", `<div class="scroll"><table><tr><th class="l">Trigger</th><th class="l">Category</th><th class="l">Kind</th><th class="l">Ages</th><th>A year</th><th></th></tr>${S.setup.triggers.map(t => `<tr><td class="l" title="${esc(t.notes ?? "")}">${esc(t.name)}</td><td class="l">${esc(catName(t.category))}</td><td class="l muted">${esc(t.kind)}</td><td class="l">${ages(t)}</td><td>${money(t.annualCost)}</td><td><button class="icon" data-action="feedback" data-kind="rule" data-section="Lifecycle trigger: ${esc(t.name)}" data-category="${esc(t.category)}">Suggest a change</button></td></tr>`).join("")}</table></div>`,
      { help: "What a child's age brings and costs a year in today's dollars" })
    + box("Categories and Inflation", `<table><tr><th class="l">Category</th><th class="l">CPI series</th><th>Assumed a year</th><th>This year</th></tr>${S.setup.categories.map(c => { const i = S.data.inflation.find(x => x.category === c.code); return `<tr><td class="l">${esc(c.name)}</td><td class="l muted">${esc(c.cpiName ?? "None")}</td><td>${pct(c.assumedInflation, 1)}</td><td>${i ? `${signedPct(i.rate)} (${i.basis})` : "—"}</td></tr>`; }).join("")}</table>`);
}

function sourcesTab() {
  const o = S.sources;
  let h = box("Time Window", `<table><tr><td class="l muted">This period</td><td class="l">${day(o.start)} – ${day(o.end)}</td></tr><tr><td class="l muted">Compared with</td><td class="l">${day(o.priorStart)} – ${day(o.priorEnd)}, the same dates a year earlier</td></tr>
    <tr><td class="l muted">Basis</td><td class="l">${S.ytd ? "Year to date" : "Whole calendar years"}</td></tr></table>`);
  h += box("Spending Sources", o.sources.map(s => {
    const kind = s.source === "bank" ? "Checking account" : s.source === "card" ? "Credit card" : "Expense ledger";
    const noSpend = s.entriesNow + s.entriesBefore === 0 && (s.entries ?? 0) > 0 && !s.spendingFirst;
    return `<div class="note"><div class="meta"><b style="color:var(--ink)">${esc(s.name)}</b><span>${esc([kind, s.code, s.institution, s.last4 && "…" + s.last4].filter(Boolean).join(" · "))}</span>${s.included ? "" : `<span class="badge left">left out</span>`}</div>
      <table>
        <tr><td class="l muted">Comes from</td><td class="l wrap">${s.source === "ledger" ? "Entered by hand in MxAcctMGR" : (s.source === "bank" ? "Entries made by hand, cleared by the bank's downloads" : "The card company's downloads") + (s.loader ? `, read by ${esc(s.loader)} on John's Mac` : "")}</td></tr>
        <tr><td class="l muted">Lands in</td><td class="l wrap">${[s.linesTable && `${s.linesTable} (${(s.lines ?? 0).toLocaleString()} lines${s.firstLine ? `, ${day(s.firstLine)} – ${day(s.lastLine)}` : ""})`, `${s.registerTable} (the register)`, "srm.v_spending_entry"].filter(Boolean).map(esc).join(" → ")}</td></tr>
        ${s.loader ? `<tr><td class="l muted">Last import</td><td class="l wrap">${s.lastImport ? `${when(s.lastImport.finishedAt)} (${age(s.lastImport.finishedAt)}), ${esc(s.lastImport.status)}` : "Never"}</td></tr>` : ""}
        <tr><td class="l muted">Register</td><td class="l wrap"${s.source !== "ledger" && s.included && daysAgo(s.last) > STALE_DAYS ? ' style="color:var(--warn)"' : ""}>${s.entries ? `${s.entries.toLocaleString()} entries, ${day(s.first)} – ${day(s.last)} (newest ${age(s.last)})` : "No entries yet"}</td></tr>
        <tr><td class="l muted">In the analysis</td><td class="l wrap">${noSpend ? "None of its entries counts as spending: none is in an expense account (card payments and transfers aren't spending)." : `${o.start.slice(0, 4)}: ${s.entriesNow.toLocaleString()} entries, ${money(s.spentNow)} · ${o.priorStart.slice(0, 4)}: ${s.entriesBefore.toLocaleString()} entries, ${money(s.spentBefore)}`}</td></tr>
      </table></div>`;
  }).join(""), { help: "Each checking account, credit card and expense ledger that can feed the analysis" });
  h += box("SRM Tables in the Aggregation", `<div class="scroll"><table><tr><th class="l">Table or view</th><th class="l">What it gives the analysis</th><th>Rows</th><th class="l">Newest data</th><th class="l">Last changed</th></tr>
    ${o.tables.map(t => `<tr><td class="l"><code>${esc(t.name)}</code></td><td class="l wrap muted">${esc(t.role)}</td><td>${t.rows.toLocaleString()}</td><td class="l">${t.newest ? `${day(t.newest)} (${age(t.newest)})` : "—"}</td><td class="l">${t.changed ? `${when(t.changed)}` : "—"}</td></tr>`).join("")}</table></div>`);
  h += box("Last Loads", `<table>${o.loaders.map(r => `<tr><td class="l"><code>${esc(r.loader.replace("_", "-"))}</code></td><td class="l">${when(r.finishedAt ?? r.startedAt)} (${age(r.finishedAt ?? r.startedAt)})</td><td class="l">${esc(r.status)}</td><td class="l wrap muted">${esc(r.message ?? "")}</td></tr>`).join("")}</table>`);
  return h;
}

// Replies John wrote since she last opened My Notes.
const unreadReplies = () => S.notes.filter(n => n.repliedAt && n.repliedAt > saved("repliesRead", "")).length;

function notesTab() {
  const latest = S.notes.map(n => n.repliedAt).filter(Boolean).sort().at(-1);
  if (latest && latest > saved("repliesRead", "")) { keep("repliesRead", latest); setTimeout(render, 0); }
  const author = saved("author", "");
  const statusText = { new: "New", seen: "Seen", planned: "Planned", done: "Done", declined: "Not planned" };
  let h = `<div class="bar"><span>Your notes to John, with what he did about them.</span><span class="spacer"></span><button class="primary" data-action="feedback">💬 New note</button></div>`;
  if (!author) return h + `<p class="muted">Send a note (💬 on any section, ⚑ on any entry) and it will show here with John's answer.</p>`;
  if (!S.notes.length) return h + `<p class="muted">No notes from ${esc(author)} yet.</p>`;
  return h + `<div class="notes">${S.notes.map(n => `<div class="note"><div class="meta"><span class="badge ${esc(n.status)}">${esc(statusText[n.status] ?? n.status)}</span><span>${when(n.createdAt)}</span><span>${esc({ layout: "How the page looks", number: "A number", rule: "A category or rule", entry: "One purchase", idea: "An idea", question: "A question" }[n.kind] ?? n.kind)}</span>${n.section ? `<span>· ${esc(n.section)}</span>` : ""}</div>
    <p class="msg">${esc(n.message)}</p>${n.suggestion ? `<p class="hint">Suggested: ${esc(n.suggestion)}</p>` : ""}
    ${n.reply ? `<div class="reply"><b>John</b>${n.repliedAt ? ` · ${when(n.repliedAt)}` : ""}<br>${esc(n.reply)}</div>` : ""}</div>`).join("")}</div>`;
}

// ---------------------------------------------------------------------------------------------------------- render

function render() {
  const app = document.getElementById("app");
  if (!S.setup || !S.data) { app.innerHTML = S.problem ? `<p class="notice warn">${esc(S.problem)}</p>` : `<div class="loading">Reading the registers…</div>`; return; }
  const body = { deepdive: diveTab, curve: curveTab, entries: () => entriesBox(entries(), "Spending Entries", false), rules: rulesTab, family: familyTab, sources: sourcesTab, notes: notesTab }[S.tab] ?? attributionTab;
  let inner;
  try { inner = body(); } catch (e) { inner = `<p class="notice warn">This part of the page failed: ${esc(e.message)}</p>`; console.error(e); }
  app.innerHTML = controls() + strip() + (S.problem ? `<p class="notice warn">${esc(S.problem)}</p>` : "") + tabsBar() + inner;
}

// ---------------------------------------------------------------------------------------------------------- feedback

let noteTarget = {};
function openNote(t) {
  noteTarget = t;
  const dlg = document.getElementById("note"), f = document.getElementById("note-form");
  f.author.value = saved("author", "");
  f.message.value = "";
  document.getElementById("note-error").textContent = "";
  const kind = t.kind || (S.tab === "rules" || S.tab === "family" ? "rule" : "idea");
  for (const r of f.kind) r.checked = r.value === kind;
  const cats = f.category, drivers = f.driver;
  cats.innerHTML = `<option value="">— no change —</option>` + S.setup.categories.map(c => `<option value="${c.code}">${esc(c.name)}</option>`).join("");
  drivers.innerHTML = `<option value="">— no change —</option>` + Object.entries(DRIVERS).map(([k, d]) => `<option value="${k}">${esc(d.title)}</option>`).join("");
  const e = t.entry;
  document.getElementById("note-about").textContent = e
    ? `About ${day(e.date)} · ${e.payee ?? e.description ?? ""} · ${money2(e.amount)} — now ${catName(e.category)}, ${driverTitle(e.driver)}`
    : `About: ${t.section || TABS.find(x => x[0] === S.tab)?.[1] || "the page"}`;
  showSuggest();
  dlg.showModal();
  (f.author.value ? f.message : f.author).focus();
}
function showSuggest() {
  const f = document.getElementById("note-form");
  document.getElementById("note-suggest").classList.toggle("on", ["rule", "entry"].includes(f.kind.value));
}
async function sendNote() {
  const f = document.getElementById("note-form"), err = document.getElementById("note-error");
  const author = f.author.value.trim(), message = f.message.value.trim();
  if (!author || !message) { err.textContent = !author ? "Your name, please, so John knows who it's from." : "Write a few words for John."; return false; }
  keep("author", author);
  const e = noteTarget.entry, suggestion = [f.category.value && "Category: " + catName(f.category.value), f.driver.value && "Driver: " + driverTitle(f.driver.value)].filter(Boolean).join("; ");
  const body = {
    author, kind: f.kind.value, tab: S.tab,
    section: noteTarget.section || (e ? `Entry: ${day(e.date)} ${e.payee ?? e.description ?? ""} ${money2(e.amount)}` : TABS.find(x => x[0] === S.tab)?.[1]),
    category: f.category.value || noteTarget.category || (S.tab === "deepdive" && S.dive !== UNASSIGNED ? S.dive : "") || null,
    entrySource: e?.source ?? null, entryId: e?.entryId ?? null, suggestion: suggestion || null, message,
    context: { year: S.year, yearToDate: S.ytd, onlyFullRegisters: S.full, ...(e ? { date: e.date, payee: e.payee, amount: e.amount, category: e.category, driver: e.driver } : {}) },
  };
  try {
    document.getElementById("note-send").disabled = true;
    S.notes = (await api("feedback", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) })).feedback;
    document.getElementById("note").close();
    toast("Thanks — John will see this in MxAcctMGR. Its answer shows under My Notes.");
    render();
  } catch (ex) { err.textContent = ex.message; } finally { document.getElementById("note-send").disabled = false; }
  return true;
}
function toast(t) { const el = document.getElementById("toast"); el.textContent = t; el.classList.add("on"); setTimeout(() => el.classList.remove("on"), 3500); }

// ---------------------------------------------------------------------------------------------------------- events

document.addEventListener("click", ev => {
  const el = ev.target.closest("[data-tab],[data-dive],[data-cat],[data-action]");
  if (!el) return;
  if (el.dataset.tab) { S.tab = el.dataset.tab; keep("tab", S.tab); S.shown = 200; render(); window.scrollTo(0, 0); return; }
  if (el.dataset.dive || el.dataset.cat) { S.dive = el.dataset.dive || el.dataset.cat; keep("dive", S.dive); S.tab = "deepdive"; keep("tab", S.tab); render(); window.scrollTo(0, 0); return; }
  const a = el.dataset.action;
  if (a === "reload") load();
  else if (a === "more") { S.shown += 200; render(); }
  else if (a === "feedback") {
    let entry = null;
    if (el.dataset.entry) { const [src, id] = el.dataset.entry.split(":"); entry = S.data.entries.find(e => e.source === src && String(e.entryId) === id); }
    openNote({ kind: el.dataset.kind, section: el.dataset.section, category: el.dataset.category || null, entry });
  }
});
document.addEventListener("change", ev => {
  const k = ev.target.dataset?.set; if (!k) return;
  const v = ev.target.type === "checkbox" ? ev.target.checked : ev.target.value;
  if (k === "year") { S.year = +v; keep("year", S.year); return load(); }
  if (k === "ytd") { S.ytd = v; keep("ytd", v); return load(); }
  if (["full", "stackBy", "inflate", "dive"].includes(k)) { S[k] = v; keep(k, v); }
  else S[k] = v;
  if (k !== "search") S.shown = 200;
  render();
});
document.addEventListener("input", ev => {
  if (ev.target.dataset?.set === "search") {
    S.search = ev.target.value;
    clearTimeout(document.searchTimer);
    document.searchTimer = setTimeout(() => { const at = ev.target.selectionStart; render(); const s = document.querySelector('[data-set="search"]'); if (s) { s.focus(); s.setSelectionRange(at, at); } }, 250);
  }
});
document.getElementById("note-form").addEventListener("change", ev => { if (ev.target.name === "kind") showSuggest(); });
document.getElementById("note-form").addEventListener("submit", ev => {
  if (ev.submitter?.value === "send") { ev.preventDefault(); sendNote(); }
});
let resizeTimer;
window.addEventListener("resize", () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(render, 200); });
load();
