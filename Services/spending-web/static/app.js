// Spending Analysis, read-only, on the home network (Services/spending-web). The same numbers as MxAcctMGR's
// Reporting ▸ Spending Analysis (SpendingModel.swift's attribution and forward curve, ported here), its target
// accounts' allocation shown read-only, without the controls that change anything, and with a note to John from every
// section, entry and target account.
"use strict";

const BASE = location.pathname.replace(/\/[^/]*$/, "");   // /s/<key>
const UNASSIGNED = "UNASSIGNED";
const EFFECTS = [
  { id: "inflation", name: "Inflation", color: "var(--inflation)", help: "Prices: last year's spending times the category's CPI change, plus what spending whose driver counts as Inflation grew beyond it" },
  { id: "usage", name: "Usage", color: "var(--usage)", help: "More (or less) of the same: what spending whose driver counts as Usage (Family Growth, New Activity …), and spending with no driver, grew beyond inflation" },
  { id: "lifecycle", name: "Lifecycle", color: "var(--lifecycle)", help: "Expected age-related costs: what spending whose driver counts as Lifecycle (Lifecycle Transition …) grew beyond inflation" },
  { id: "behavior", name: "Behavior", color: "var(--behavior)", help: "Habits, tastes and hobbies: what spending whose driver counts as Behavior (Preference Change, Lifestyle & Hobbies …) grew beyond inflation" },
  { id: "oneTime", name: "One-Time", color: "var(--onetime)", help: "Events that won't repeat: what spending whose driver counts as One-Time (One-Time Event …) grew beyond inflation" },
  { id: "taxes", name: "Taxes", color: "var(--taxes)", help: "Taxes: what spending whose driver counts as Taxes grew beyond inflation" },
];
// The drivers until the setup gives them (srm.spending_driver, V047, changed in MxAcctMGR's Admin): useDrivers.
let DRIVERS = {
  inflation: { title: "Inflation", effect: "inflation", help: "The same thing costs more" },
  family_growth: { title: "Family Growth", effect: "usage", help: "More people, more of the same things" },
  new_activity: { title: "New Activity", effect: "usage", help: "Something the family didn't do before" },
  lifecycle: { title: "Lifecycle Transition", effect: "lifecycle", help: "Expected age-related spending: tutors, driving, college" },
  preference: { title: "Preference Change", effect: "behavior", help: "A habit or taste changed" },
  lifestyle: { title: "Lifestyle & Hobbies", effect: "behavior", help: "The family's hobbies and way of living: music gear and lessons, sports, crafts, clubs" },
  one_time: { title: "One-Time Event", effect: "oneTime", help: "An event that won't repeat" },
  taxes: { title: "Taxes", effect: "taxes", help: "Taxes changed: real estate, income, local or sales taxes and their fees" },
};
const DRIVER_COLORS = ["#e67e22", "#2e86de", "#17a2b8", "#8e44ad", "#d6336c", "#5c6bc0", "#16a085", "#8d6e63", "#2ecc71", "#c0392b", "#f1c40f", "#34495e"];
const driverColor = (d, i) => d ? DRIVER_COLORS[i % DRIVER_COLORS.length] : "#a0a0a0";   // "": no driver
const CHILD_COLORS = ["#2e86de", "#e67e22", "#8e44ad", "#16a085", "#d6336c", "#b9770e"];
const TABS = [["attribution", "Overview"], ["deepdive", "Deep Dive"], ["curve", "Forward Curve"], ["tax", "Year-End Tax"], ["entries", "Entries"],
              ["rules", "Allocation"], ["family", "Family & Lifecycle"], ["sources", "Sources"], ["notes", "My Notes"]];
const STALE_DAYS = 14, STALE_CPI_DAYS = 75;

// ---------------------------------------------------------------------------------------------------------- state

const saved = (k, d) => { try { const v = localStorage.getItem("spending." + k); return v === null ? d : JSON.parse(v); } catch { return d; } };
const keep = (k, v) => { try { localStorage.setItem("spending." + k, JSON.stringify(v)); } catch { /* private window */ } };
const thisYear = new Date().getFullYear();
const S = {
  // A tab saved before the Forward Curve or Rules left this page opens the Overview.
  tab: saved("tab", "attribution"), year: saved("year", thisYear), ytd: saved("ytd", true), full: saved("full", true),
  dive: saved("dive", "HEALTHCARE"), stackBy: saved("stackBy", "child"), inflate: saved("inflate", true),
  taxYear: saved("taxYear", new Date().getMonth() < 4 ? thisYear - 1 : thisYear), tax: null, taxProblem: null,
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
// What an Amazon charge bought (matched to its order, V046): "Swim Goggles and 1 more", and every item with its cost.
const itemLabel = i => (i.quantity > 1 ? `${i.quantity} × ` : "") + i.name;
const bought = e => e.amazonItems?.length ? itemLabel(e.amazonItems[0]) + (e.amazonItems.length > 1 ? ` and ${e.amazonItems.length - 1} more` : "") : "";
// Its orders on amazon.com, as MxAcctMGR links them (whoever opens one signs in to Amazon there).
const amazonOrders = e => [...new Set((e.amazonItems ?? []).map(i => i.orderId).filter(id => /^[0-9D]\d{2}-\d{7}-\d{7}$/.test(id ?? "")))];
const amazonOrderURL = id => "https://www.amazon.com/gp/your-account/order-details?orderID=" + encodeURIComponent(id);
const boughtDetail = e => {
  if (!e.amazonItems?.length) return "";
  const orders = amazonOrders(e);
  return (e.amount < 0 ? "Refunded:\n" : "Bought:\n") + e.amazonItems.map(i => itemLabel(i) + (i.amount != null ? " — " + money2(i.amount) : "")).join("\n")
    + (orders.length ? `\nAmazon order${orders.length === 1 ? "" : "s"} ${orders.join(", ")}` : "")
    + (e.amazonMatchedBy === "amazon-lookup" ? " — from Amazon's Transactions list" : e.amazonMatchedBy === "amazon-orders" ? " — matched by amount and date" : "");
};
// What was bought, as a link to its (first) order; the items and every order on hover.
const boughtLink = (e, fallback = "") => {
  const orders = amazonOrders(e);
  if (!orders.length) return esc(fallback);
  return `<a href="${esc(amazonOrderURL(orders[0]))}" target="_blank" rel="noopener noreferrer" title="${esc(boughtDetail(e))}">${esc(bought(e))}</a>`;
};
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
    useDrivers(setup.drivers);
    await loadNotes();
  } catch (e) { S.problem = e.message; }
  S.busy = false; render();
}

// The setup's drivers, {code, title, help, effect} (an older accounts service sends only their codes: the built-in
// list stays).
function useDrivers(list) {
  if (!Array.isArray(list) || !list.length || typeof list[0] !== "object") return;
  DRIVERS = Object.fromEntries(list.map(d => [d.code, { title: d.title, effect: d.effect === "one_time" ? "oneTime" : d.effect, help: d.help ?? "" }]));
}

// Her notes and changes: under the name given for notes, else the changes signed "Family page".
async function loadNotes() {
  S.notes = (await api("feedback?author=" + encodeURIComponent(whoAmI()))).feedback;
}

// ---------------------------------------------------------------------------------------------------------- engine
// As SpendingEngine (SpendingModel.swift): change = inflation + usage + lifecycle + behavior + one-time + taxes.

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
    if ((r.share("taxes") ?? 0) >= 0.5) return "Taxes";
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

// As SpendingEngine.forwardCurve and waves (SpendingModel.swift): each child's lifecycle costs, ten years ahead.
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
    ${["inflation", "lifecycle", "behavior"].concat(Math.abs(t.effect("taxes")) >= 0.5 ? ["taxes"] : []).map(id => { const e = EFFECTS.find(x => x.id === id); return tile(e.name, money(t.effect(id)), t.share(id) === null ? "" : `${pct(t.share(id))} of the change`, e.help); }).join("")}</div>`;
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
    return { label: catName(code), cat: code, segs: drv.filter(d => by[d]).map(d => ({ name: driverTitle(d || null), value: by[d].reduce((a, e) => a + e.amount, 0), color: driverColor(d, drv.indexOf(d)) })) };
  }).filter(Boolean);
  h += box("This Year by Category and Driver", columns({ cols, catAttr: true }) + legend(drv.map((d, i) => [driverTitle(d || null), driverColor(d, i)])),
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
    <span class="spacer"></span><button data-tab="attribution">‹ Overview</button></div>`;
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
    ${Object.keys(DRIVERS).concat([""]).filter(d => byDriver[d]).map(d => { const s = sums(byDriver[d]); const eff = EFFECTS.find(e => e.id === (DRIVERS[d]?.effect ?? "usage")); return `<tr><td class="l" title="${esc(DRIVERS[d]?.help ?? "No target account or tag gives it a driver")}">${esc(DRIVERS[d]?.title ?? "No driver yet")}</td><td>${money(s.before)}</td><td>${money(s.now)}</td><td class="${cls(s.change)}">${money(s.change)}</td><td>${money(s.now - s.before * (1 + r.rate))}</td><td class="l">${eff.name}</td></tr>`; }).join("")}
    <tr class="total"><td class="l">Change</td><td>${money(r.prior)}</td><td>${money(r.current)}</td><td>${money(r.change)}</td><td>${money(r.change)}</td><td></td></tr></table></div>`, { section: `Deep Dive ${name}: drivers` });
  // How entries got here.
  const origins = group(mine, e => (e.categoryFrom ?? "none") + "|" + (e.categoryFrom === "entry" ? "Tagged on the entry" : e.payee ?? "—"));
  const allocText = label => { const p = S.setup.payees.find(x => x.name === label); return p ? [p.category && catName(p.category), p.driver && driverTitle(p.driver), memberName(p.memberId)].filter(Boolean).join(" · ") : ""; };
  h += box("How Entries Got Here", `<div class="scroll"><table><tr><th class="l">Put here by</th><th class="l">Allocated as</th><th>${py}</th><th>${y}</th><th>Change</th><th>Entries</th><th></th></tr>
    ${Object.entries(origins).sort((a, b) => Math.abs(sums(b[1]).now) + Math.abs(sums(b[1]).before) - Math.abs(sums(a[1]).now) - Math.abs(sums(a[1]).before)).map(([k, list]) => {
      const [kind, ...rest] = k.split("|"), label = rest.join("|"); const s = sums(list);
      return `<tr><td class="l">${esc(label)}<br><span class="muted">${kind === "none" ? "target account not allocated" : kind === "entry" ? "entry tags" : "target account"}</span></td><td class="l muted">${esc(kind === "entry" ? "" : allocText(label))}</td><td>${money(s.before)}</td><td>${money(s.now)}</td><td class="${cls(s.change)}">${money(s.change)}</td><td>${s.countBefore} → ${s.count}</td>
        <td>${kind === "entry" ? "" : `<button class="icon" data-action="feedback" data-kind="rule" data-section="Target account: ${esc(label)}" data-category="${esc(code)}">Suggest a change</button>`}</td></tr>`;
    }).join("")}</table></div>`, { section: `Deep Dive ${name}: how entries got here`, help: "What put each entry in this category: its target account's allocation (the provider, merchant or vendor paid), or the entry's own tag" });
  // Where it went: the target accounts paid, the largest first.
  const byTarget = group(mine, e => e.payee ?? e.description ?? "—");
  const targets = Object.keys(byTarget).sort((p, q) => sums(byTarget[q]).now - sums(byTarget[p]).now);
  let w = targets.slice(0, 15).map(p => { const s = sums(byTarget[p]); return `<tr><td class="l">${esc(p)}</td><td>${money(s.before)}</td><td>${money(s.now)}</td><td class="${cls(s.change)}">${money(s.change)}</td><td>${s.countBefore} → ${s.count}</td></tr>`; }).join("");
  if (targets.length > 15) { const rest = sums(targets.slice(15).flatMap(p => byTarget[p])); w += `<tr class="muted"><td class="l">${targets.length - 15} more</td><td>${money(rest.before)}</td><td>${money(rest.now)}</td><td>${money(rest.change)}</td><td>${rest.countBefore} → ${rest.count}</td></tr>`; }
  h += box("Where It Went", `<div class="scroll"><table><tr><th class="l">Target account</th><th>${py}</th><th>${y}</th><th>Change</th><th>Entries</th></tr>${w}</table></div>`, { section: `Deep Dive ${name}: where it went` });
  const top = mine.filter(inNow).sort((a, b) => b.amount - a.amount).slice(0, 10);
  const byMember = group(mine, e => e.memberId ?? 0);
  h += `<div class="row">${box("Largest This Year", `<div class="scroll"><table>${top.map(e => `<tr><td class="l muted">${day(e.date)}</td><td class="l" title="${esc(e.payee ?? e.description ?? "")}">${boughtLink(e, e.payee ?? e.description ?? "—")}</td><td>${money2(e.amount)}</td><td class="l muted">${esc(e.event ?? driverTitle(e.driver))}</td><td>${flag(e)}</td></tr>`).join("")}</table></div>`, { section: `Deep Dive ${name}: largest` })}
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
const KINDS = { recurring: "Recurring", replacement: "Replacement", peak: "Peak event", transition: "Transition" };
const ages = t => (t.ageFrom === t.ageTo ? `${t.ageFrom}` : `${t.ageFrom}–${t.ageTo}`) + (t.everyYears > 1 ? `, every ${t.everyYears} years` : "");

// An entry's category or driver as a choice: changing it gives the entry a tag of its own (V041), listed for John.
function pick(field, e) {
  const now = field === "category" ? e.category : e.driver;
  const choices = field === "category" ? S.setup.categories.map(c => [c.code, c.name]) : Object.entries(DRIVERS).map(([k, d]) => [k, d.title]);
  return `<select class="cell" data-edit-entry="${esc(e.source)}:${e.entryId}" data-field="${field}">
    <option value=""${now ? "" : " selected"}>${now ? "By the target account" : field === "category" ? "Not assigned" : "No driver"}</option>
    ${choices.map(([v, t]) => `<option value="${esc(v)}"${v === now ? " selected" : ""}>${esc(t)}</option>`).join("")}</select>`;
}

function flag(e) {
  return `<button class="icon" data-action="feedback" data-kind="entry" data-entry="${esc(e.source)}:${e.entryId}" title="Something's off with this entry? Tell John">⚑</button>`;
}

function entriesBox(list, title, locked) {
  const q = S.search.toLowerCase();
  const rows = list.filter(e => (S.period === "both" || (S.period === "current") === inNow(e))
    && (!S.unassignedOnly || !e.driver) && (locked || !S.cat || (e.category ?? UNASSIGNED) === S.cat)
    && (!q || [e.payee, e.description, e.event, e.register, (e.amazonItems ?? []).map(i => i.name).join("\n")].some(v => (v ?? "").toLowerCase().includes(q))))
    .sort((a, b) => a.date < b.date ? 1 : -1);
  const body = `<div class="bar">
      <select data-set="period"><option value="current"${S.period === "current" ? " selected" : ""}>This year</option><option value="prior"${S.period === "prior" ? " selected" : ""}>Earlier year</option><option value="both"${S.period === "both" ? " selected" : ""}>Both</option></select>
      ${locked ? "" : `<select data-set="cat"><option value="">All categories</option>${S.setup.categories.map(c => `<option value="${c.code}"${S.cat === c.code ? " selected" : ""}>${esc(c.name)}</option>`).join("")}<option value="${UNASSIGNED}"${S.cat === UNASSIGNED ? " selected" : ""}>Not assigned</option></select>`}
      <label><input type="checkbox" data-set="unassignedOnly"${S.unassignedOnly ? " checked" : ""}> No driver yet</label>
      <input type="search" data-set="search" value="${esc(S.search)}" placeholder="Search payee, item bought, event">
      <span class="spacer"></span><span class="muted">${rows.length.toLocaleString()} entries, ${money(rows.reduce((a, e) => a + e.amount, 0))}</span></div>
    <div class="scroll"><table><tr><th class="l">Date</th><th class="l">From</th><th class="l payee">Payee<span class="grip" data-resize="payee" title="Drag to make Payee wider or narrower; double-click for the standard width"></span></th><th class="l bought">Bought<span class="grip" data-resize="bought" title="Drag to make Bought wider or narrower; double-click for the standard width"></span></th><th>Amount</th><th class="l">Category</th><th class="l">Driver</th><th class="l">Family member</th><th class="l">Event</th><th></th></tr>
    ${rows.slice(0, S.shown).map(e => `<tr><td class="l">${day(e.date)}</td><td class="l muted">${esc(e.register ?? e.source)}</td><td class="l payee" title="${esc(e.payee ?? e.description ?? "")}">${esc(e.payee ?? e.description ?? "")}</td>
      <td class="l bought">${boughtLink(e)}</td><td>${money2(e.amount)}</td><td class="l" title="${esc(e.categoryFrom ? "Now from the " + e.categoryFrom : "Its target account isn't allocated")}">${pick("category", e)}</td><td class="l" title="${esc(e.driverFrom ? "Now from the " + e.driverFrom : "Its target account has no driver: counts as usage")}">${pick("driver", e)}</td>
      <td class="l muted">${esc(memberName(e.memberId) ?? "")}</td><td class="l muted">${esc(e.event ?? "")}</td><td>${flag(e)}</td></tr>`).join("")}</table></div>
    ${rows.length > S.shown ? `<p><button data-action="more">Show ${Math.min(200, rows.length - S.shown)} more</button></p>` : ""}`;
  return box(title, body, { section: title, help: "Every spending dollar: its category and driver and where they came from, and for an Amazon charge what was bought — a link to the order on amazon.com. ⚑ tells John something about one entry." });
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

// The target accounts' allocation, read-only (MxAcctMGR's Allocation tab changes it): each with both years' spending
// and a note to John.
function allocationTab() {
  const spent = {};
  for (const e of entries()) { const s = spent[e.payeeId] ?? (spent[e.payeeId] = { before: 0, now: 0 }); if (inNow(e)) s.now += e.amount; else if (inBefore(e)) s.before += e.amount; }
  const py = S.data.priorStart.slice(0, 4), y = S.data.start.slice(0, 4);
  const shown = S.setup.payees.filter(p => (p.role ?? "spending") === "spending" && (spent[p.id] || p.category || p.driver))
    .sort((a, b) => (spent[b.id]?.now ?? 0) - (spent[a.id]?.now ?? 0) || (spent[b.id]?.before ?? 0) - (spent[a.id]?.before ?? 0));
  const left = S.setup.payees.filter(p => p.role === "transfer" || p.role === "income");
  const row = p => `<tr><td class="l">${esc(p.name)}${(p.patterns ?? []).length ? `<br><span class="muted">statement names containing ${esc(p.patterns.join(", "))}</span>` : ""}</td><td>${money(spent[p.id]?.before ?? 0)}</td><td>${money(spent[p.id]?.now ?? 0)}</td><td class="l">${esc(p.category ? catName(p.category) : "Not assigned")}</td><td class="l">${esc(p.driver ? driverTitle(p.driver) : "—")}</td><td class="l muted">${esc(memberName(p.memberId) ?? "")}</td>
    <td><button class="icon" data-action="feedback" data-kind="rule" data-section="Target account: ${esc(p.name)}" data-category="${esc(p.category ?? "")}">Suggest a change</button></td></tr>`;
  return `<p class="hint">Every payment from the checking accounts and credit cards goes to a target account: the provider, merchant or vendor paid. Each dollar's category and driver come from the entry's own tag if it has one, else its target account's allocation. Transfers between our own accounts, income and the cash ledgers aren't spending. John changes the allocation in MxAcctMGR; Suggest a change tells him.</p>`
    + box("Target Accounts", shown.length ? `<div class="scroll"><table><tr><th class="l">Target account</th><th>${py}</th><th>${y}</th><th class="l">Category</th><th class="l">Driver</th><th class="l">Family member</th><th></th></tr>${shown.map(row).join("")}</table></div>` : `<p class="muted">No target account is allocated yet.</p>`,
      { help: "The category, driver and family member of each target account's spending, the largest first" + (left.length ? `; ${left.length} more are transfers or income and left out` : "") });
}

function familyTab() {
  const grade = a => a < 5 ? "Preschool" : a === 5 ? "Kindergarten" : a <= 17 ? `Grade ${a - 5}` : a <= 21 ? `College year ${a - 17}` : "";
  return box("Family", S.setup.members.length ? `<table><tr><th class="l">Name</th><th class="l">Relation</th><th>Born</th><th>Age</th><th class="l">Grade</th></tr>${S.setup.members.map(m => `<tr><td class="l">${esc(m.name)}</td><td class="l">${esc(m.relation)}</td><td>${m.birthMonth ? m.birthMonth + "/" : ""}${m.birthYear}</td><td>${thisYear - m.birthYear}</td><td class="l muted">${m.relation === "child" ? grade(thisYear - m.birthYear) : ""}</td></tr>`).join("")}</table>` : `<p class="muted">No one is set up yet.</p>`)
    + box("Lifecycle Triggers", `<div class="scroll"><table><tr><th class="l">Trigger</th><th class="l">Category</th><th class="l">Kind</th><th class="l">Ages</th><th>A year</th><th></th></tr>${S.setup.triggers.map(t => `<tr><td class="l" title="${esc(t.notes ?? "")}">${esc(t.name)}</td>
        <td class="l"><select class="cell" data-edit-trigger="${t.id}" data-field="category">${S.setup.categories.map(c => `<option value="${c.code}"${c.code === t.category ? " selected" : ""}>${esc(c.name)}</option>`).join("")}</select></td>
        <td class="l"><select class="cell" data-edit-trigger="${t.id}" data-field="kind">${Object.entries(KINDS).map(([k, n]) => `<option value="${k}"${k === t.kind ? " selected" : ""}>${n}</option>`).join("")}</select></td><td class="l">${ages(t)}</td><td>${money(t.annualCost)}</td><td><button class="icon" data-action="feedback" data-kind="rule" data-section="Lifecycle trigger: ${esc(t.name)}" data-category="${esc(t.category)}">Suggest a change</button></td></tr>`).join("")}</table></div>`,
      { help: "What a child's age brings and costs a year in today's dollars" })
    + box("Categories and Inflation", `<table><tr><th class="l">Category</th><th class="l">CPI series</th><th>Assumed a year</th><th>This year</th></tr>${S.setup.categories.map(c => { const i = S.data.inflation.find(x => x.category === c.code); return `<tr><td class="l">${esc(c.name)}</td><td class="l muted">${esc(c.cpiName ?? "None")}</td><td>${pct(c.assumedInflation, 1)}</td><td>${i ? `${signedPct(i.rate)} (${i.basis})` : "—"}</td></tr>`; }).join("")}</table>`);
}

function sourcesTab() {
  const o = S.sources;
  let h = box("Time Window", `<table><tr><td class="l muted">This period</td><td class="l">${day(o.start)} – ${day(o.end)}</td></tr><tr><td class="l muted">Compared with</td><td class="l">${day(o.priorStart)} – ${day(o.priorEnd)}, the same dates a year earlier</td></tr>
    <tr><td class="l muted">Basis</td><td class="l">${S.ytd ? "Year to date" : "Whole calendar years"}</td></tr></table>`);
  h += box("Spending Sources", o.sources.map(s => {
    const kind = s.source === "bank" ? "Checking account" : s.source === "card" ? "Credit card" : "Cash ledger";
    const noSpend = s.entriesNow + s.entriesBefore === 0 && (s.entries ?? 0) > 0 && !s.spendingFirst;
    return `<div class="note"><div class="meta"><b style="color:var(--ink)">${esc(s.name)}</b><span>${esc([kind, s.code, s.institution, s.last4 && "…" + s.last4].filter(Boolean).join(" · "))}</span>${s.included ? "" : `<span class="badge left">left out</span>`}</div>
      <table>
        <tr><td class="l muted">Comes from</td><td class="l wrap">${s.source === "ledger" ? "Entered by hand in MxAcctMGR" : (s.source === "bank" ? "Entries made by hand, cleared by the bank's downloads" : "The card company's downloads") + (s.loader ? `, read by ${esc(s.loader)} on John's Mac` : "")}</td></tr>
        <tr><td class="l muted">Lands in</td><td class="l wrap">${[s.linesTable && `${s.linesTable} (${(s.lines ?? 0).toLocaleString()} lines${s.firstLine ? `, ${day(s.firstLine)} – ${day(s.lastLine)}` : ""})`, `${s.registerTable} (the register)`, "srm.v_spending_entry"].filter(Boolean).map(esc).join(" → ")}</td></tr>
        ${s.loader ? `<tr><td class="l muted">Last import</td><td class="l wrap">${s.lastImport ? `${when(s.lastImport.finishedAt)} (${age(s.lastImport.finishedAt)}), ${esc(s.lastImport.status)}` : "Never"}</td></tr>` : ""}
        <tr><td class="l muted">Register</td><td class="l wrap"${s.source !== "ledger" && s.included && daysAgo(s.last) > STALE_DAYS ? ' style="color:var(--warn)"' : ""}>${s.entries ? `${s.entries.toLocaleString()} entries, ${day(s.first)} – ${day(s.last)} (newest ${age(s.last)})` : "No entries yet"}</td></tr>
        <tr><td class="l muted">In the analysis</td><td class="l wrap">${noSpend ? "None of its entries counts as spending: none is in an expense account (card payments and transfers aren't spending)." : `${o.start.slice(0, 4)}: ${s.entriesNow.toLocaleString()} entries, ${money(s.spentNow)} · ${o.priorStart.slice(0, 4)}: ${s.entriesBefore.toLocaleString()} entries, ${money(s.spentBefore)}`}</td></tr>
      </table></div>`;
  }).join(""), { help: "Each checking account, credit card and cash ledger that can feed the analysis" });
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
  const statusText = { new: "New", seen: "Seen", planned: "Planned", done: "Done", declined: "Not planned" };
  const changeStatus = { new: "Made", seen: "Seen", planned: "Kept", done: "Kept", declined: "Undone" };
  let h = `<div class="bar"><span>Your notes to John, with what he did about them.</span><span class="spacer"></span><button class="primary" data-action="feedback">💬 New note</button></div>`;
  if (!S.notes.length) return h + `<p class="muted">Send a note (💬 on any section, ⚑ on any entry) and it will show here with John's answer.</p>`;
  return h + `<div class="notes">${S.notes.map(n => `<div class="note"><div class="meta"><span class="badge ${esc(n.status)}">${esc((n.kind === "change" ? changeStatus : statusText)[n.status] ?? n.status)}</span><span>${when(n.createdAt)}</span><span>${esc({ layout: "How the page looks", number: "A number", rule: "A category or allocation", entry: "One purchase", idea: "An idea", question: "A question", change: "A change you made" }[n.kind] ?? n.kind)}</span>${n.section ? `<span>· ${esc(n.section)}</span>` : ""}</div>
    <p class="msg">${esc(n.message)}</p>${n.suggestion ? `<p class="hint">Suggested: ${esc(n.suggestion)}</p>` : ""}
    ${n.reply ? `<div class="reply"><b>John</b>${n.repliedAt ? ` · ${when(n.repliedAt)}` : ""}<br>${esc(n.reply)}</div>` : ""}</div>`).join("")}</div>`;
}

// ---------------------------------------------------------------------------------------------------------- tax

const TAX_SECTIONS = { expense: "Tax-applicable expense", payment: "Tax payment", real_estate: "Real estate tax", refund: "Refund received", savings: "Tax savings account" };
const JURISDICTIONS = [["federal", "Federal"], ["state", "State (PA)"], ["local", "Local"]];

async function loadTax() {
  S.taxProblem = null;
  try { S.tax = await api("tax?year=" + S.taxYear); } catch (e) { S.taxProblem = e.message; }
  render();
}

function taxTab() {
  const years = []; for (let y = thisYear; y >= thisYear - 5; y--) years.push(y);
  let h = `<div class="bar"><label>Tax year <select data-set="taxYear">${years.map(y => `<option value="${y}"${y === S.taxYear ? " selected" : ""}>${y}</option>`).join("")}</select></label>
    <span class="spacer"></span><button data-action="taxcsv"${S.tax ? "" : " disabled"}>⬇︎ Download CSV</button></div>`;
  if (S.taxProblem) return h + `<p class="notice warn">${esc(S.taxProblem)}</p>`;
  const r = S.tax;
  if (!r || r.year !== S.taxYear) { if (!S.taxLoading) { S.taxLoading = true; loadTax().finally(() => S.taxLoading = false); } return h + `<div class="loading">Reading the registers…</div>`; }
  const item = id => r.items.find(i => i.id === id), s = r.summary;
  const of = section => r.entries.filter(e => item(e.itemId)?.section === section);
  if (r.partialRegisters.length) h += `<p class="notice warn">Incomplete for ${r.year}: ${esc(r.partialRegisters.map(p => `${p.name} starts ${day(p.first)}`).join("; "))}. Payments before then aren't in the registers, so the totals miss them.</p>`;
  h += `<div class="tiles">${tile("Tax-applicable expenses", money(s.expensesPaid), `${money(s.expensesDeductible)} deductible`)}
    ${tile("Tax payments", money(s.paymentsTotal), JURISDICTIONS.filter(([j]) => s.payments[j]?.total > 0).map(([j, t]) => `${t} ${money(s.payments[j].total)}`).join(" · "))}
    ${tile("Real estate taxes", money(s.realEstate))}${tile("Refunds received", money(s.refunds), `for ${r.year}`)}
    ${tile("Tax savings", money(s.savingsSetAside - s.savingsTakenOut), `${money(s.savingsSetAside)} in, ${money(s.savingsTakenOut)} out`)}</div>`;
  // Expenses by category.
  const exp = r.items.filter(i => i.section === "expense" && i.active), cats = [...new Set(exp.map(i => i.taxCategory))].sort();
  h += box("Tax-Applicable Expenses", `<div class="scroll"><table><tr><th class="l">Item</th><th class="l">Comes from</th><th>Payments</th><th>Paid</th><th>Share</th><th>Deductible</th></tr>
    ${cats.map(c => { const list = exp.filter(i => i.taxCategory === c); return `<tr class="total"><td class="l" colspan="3">${esc(c)}</td><td>${money(list.reduce((a, i) => a + i.paid, 0))}</td><td></td><td>${money(list.reduce((a, i) => a + (i.deductible ?? 0), 0))}</td></tr>`
      + list.map(i => `<tr><td class="l" style="padding-left:22px">${esc(i.label)}</td><td class="l muted">${esc(origin(i))}</td><td class="muted">${i.entries}</td><td>${money(i.paid)}</td><td>${pct(i.deductibleShare)}</td><td>${money(i.deductible ?? 0)}</td></tr>`).join(""); }).join("")}
    <tr class="total"><td class="l" colspan="3">All tax-applicable expenses</td><td>${money(s.expensesPaid)}</td><td></td><td>${money(s.expensesDeductible)}</td></tr></table></div>`,
    { section: "Year-End Tax: expenses", help: "What each item cost in the year and its deductible part (the business or home-office share)" });
  const rows = (list, sign = 1) => list.length ? `<div class="scroll"><table>${list.map(e => `<tr><td class="l muted">${day(e.date)}</td><td class="l">${esc(item(e.itemId)?.section === "savings" ? (e.amount >= 0 ? "Set aside" : "Taken out") : item(e.itemId)?.label)}</td><td class="l muted">${esc(e.payee ?? e.description ?? "")}</td><td>${money2(sign * e.amount)}</td><td class="l muted">${e.quarter ? `${e.taxYear} Q${e.quarter}` : e.taxYear}${e.moved ? " (moved)" : ""}</td></tr>`).join("")}</table></div>` : `<p class="muted">None in ${r.year}.</p>`;
  h += box("Tax Payments Through the Year", `<div class="scroll"><table><tr><th class="l">Jurisdiction</th><th>Q1</th><th>Q2</th><th>Q3</th><th>Q4</th><th>Other</th><th>Total</th></tr>
    ${JURISDICTIONS.map(([j, t]) => { const q = s.payments[j] ?? {}; return `<tr><td class="l">${t}</td>${["q1", "q2", "q3", "q4", "other", "total"].map(k => `<td${k === "total" ? ' style="font-weight:650"' : ""}>${q[k] ? money(q[k]) : "—"}</td>`).join("")}</tr>`; }).join("")}
    <tr class="total"><td class="l">All</td><td></td><td></td><td></td><td></td><td></td><td>${money(s.paymentsTotal)}</td></tr></table></div>${rows(of("payment"))}`,
    { section: "Year-End Tax: payments", help: "Estimated payments count toward their quarter; January counts as Q4 of the year before" });
  h += `<div class="row">${box("Real Estate Taxes", rows(of("real_estate")), { section: "Year-End Tax: real estate" })}${box("Refunds Received", rows(of("refund"), -1), { section: "Year-End Tax: refunds", help: "Refunds for this year's return, received the year after" })}</div>`;
  h += box("Tax Savings Account", `<p>${money(s.savingsSetAside)} set aside, ${money(s.savingsTakenOut)} taken out: ${money(s.savingsSetAside - s.savingsTakenOut)} net.</p>${rows(of("savings"))}`, { section: "Year-End Tax: savings" });
  h += box("Tax Items", `<div class="scroll"><table><tr><th class="l">Item</th><th class="l">Section</th><th class="l">Category</th><th class="l">Comes from</th><th>Share</th><th></th></tr>
    ${r.items.map(i => `<tr><td class="l">${esc(i.label)}</td><td class="l muted">${esc(TAX_SECTIONS[i.section])}</td><td class="l muted">${esc(i.taxCategory)}${i.jurisdiction ? " · " + esc(i.jurisdiction) : ""}${i.quarterly ? " · quarterly" : ""}</td><td class="l muted">${esc(origin(i))}</td><td>${["expense", "real_estate"].includes(i.section) ? pct(i.deductibleShare) : ""}</td>
      <td><button class="icon" data-action="feedback" data-kind="rule" data-section="Tax item: ${esc(i.label)}">Suggest a change</button></td></tr>`).join("")}</table></div>`,
    { section: "Year-End Tax: items", help: "What makes a payment a tax item" });
  return h;
}
const origin = i => i.payee ? `Target account ${i.payee}` : i.ledgerLine ? `Ledger ${i.ledger ?? ""} line ${i.ledgerLine}` : i.namePattern ? `Card names containing ${i.namePattern}` : "";

// As TaxReport.csv (SpendingModel.swift): every payment, then each item's totals and the payments by quarter.
function taxCsv(r) {
  const f = v => { v = v == null ? "" : String(v); return /[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v; };
  const n = x => x.toFixed(2), item = id => r.items.find(i => i.id === id);
  const rows = [`Year-End Tax ${r.year}`, "", "Section,Item,Category,Jurisdiction,Date,Payee,Register,Amount,Deductible share,Deductible,Tax year,Quarter,Note"];
  for (const e of r.entries) {
    const i = item(e.itemId); if (!i) continue;
    const d = ["expense", "real_estate"].includes(i.section);
    rows.push([TAX_SECTIONS[i.section], i.label, i.taxCategory, i.jurisdiction, e.date, e.payee ?? e.description, e.register, n(e.amount), d ? pct(i.deductibleShare) : "", d ? n(e.amount * i.deductibleShare) : "", e.taxYear, e.quarter ? "Q" + e.quarter : "", e.note].map(f).join(","));
  }
  rows.push("", "Totals", "Section,Item,Category,Paid,Deductible share,Deductible,Payments");
  for (const i of r.items.filter(i => i.entries > 0)) rows.push([TAX_SECTIONS[i.section], i.label, i.taxCategory, n(i.paid), i.deductible == null ? "" : pct(i.deductibleShare), i.deductible == null ? "" : n(i.deductible), i.entries].map(f).join(","));
  rows.push("", "Estimated and local tax payments", "Jurisdiction,Q1,Q2,Q3,Q4,Other,Total");
  for (const [j, t] of JURISDICTIONS) { const q = r.summary.payments[j]; if (q) rows.push([t, ...["q1", "q2", "q3", "q4", "other", "total"].map(k => n(q[k]))].join(",")); }
  const s = r.summary;
  rows.push("", "Summary", `Tax-applicable expenses paid,${n(s.expensesPaid)}`, `Deductible,${n(s.expensesDeductible)}`, `Tax payments,${n(s.paymentsTotal)}`,
    `Real estate taxes,${n(s.realEstate)}`, `Refunds received,${n(s.refunds)}`, `Tax savings set aside,${n(s.savingsSetAside)}`, `Tax savings taken out,${n(s.savingsTakenOut)}`);
  return rows.join("\n") + "\n";
}
function downloadTaxCsv() {
  const url = URL.createObjectURL(new Blob([taxCsv(S.tax)], { type: "text/csv" }));
  const a = Object.assign(document.createElement("a"), { href: url, download: `Year-End Tax ${S.tax.year}.csv` });
  document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// ---------------------------------------------------------------------------------------------------------- render

function render() {
  const app = document.getElementById("app");
  if (!S.setup || !S.data) { app.innerHTML = S.problem ? `<p class="notice warn">${esc(S.problem)}</p>` : `<div class="loading">Reading the registers…</div>`; return; }
  const body = { deepdive: diveTab, curve: curveTab, tax: taxTab, entries: () => entriesBox(entries(), "Spending Entries", false), rules: allocationTab, family: familyTab, sources: sourcesTab, notes: notesTab }[S.tab] ?? attributionTab;
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

// ---------------------------------------------------------------------------------------------------------- changes
// Applied at once, without asking anything: signed with the name given for notes, else "Family page". Each one shows
// in John's Feedback tab, where he can undo it.

const whoAmI = () => saved("author", "") || "Family page";

async function changeEntry(sel) {
  const author = whoAmI();
  const [source, id] = sel.dataset.editEntry.split(":");
  try {
    const { entry } = await api(`entry/${source}/${id}`, { method: "PUT", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ author, tab: S.tab, [sel.dataset.field]: sel.value }) });
    const i = S.data.entries.findIndex(e => e.source === entry.source && e.entryId === entry.entryId);
    if (i >= 0) S.data.entries[i] = entry;
    await loadNotes();
    toast(`Changed: ${sel.dataset.field} ${sel.dataset.field === "category" ? catName(entry.category) : driverTitle(entry.driver)}. John sees it in MxAcctMGR.`);
  } catch (ex) { toast("Not changed: " + ex.message); }
  render();
}

async function changeTrigger(sel) {
  const author = whoAmI();
  try {
    const { triggers } = await api(`trigger/${sel.dataset.editTrigger}`, { method: "PUT", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ author, tab: S.tab, [sel.dataset.field]: sel.value }) });
    S.setup.triggers = triggers;
    await loadNotes();
    toast("Changed. John sees it in MxAcctMGR.");
  } catch (ex) { toast("Not changed: " + ex.message); }
  render();
}

// ---------------------------------------------------------------------------------------------------------- events

document.addEventListener("click", ev => {
  const el = ev.target.closest("[data-tab],[data-dive],[data-cat],[data-action]");
  if (!el) return;
  if (el.dataset.tab) { S.tab = el.dataset.tab; keep("tab", S.tab); S.shown = 200; render(); window.scrollTo(0, 0); return; }
  if (el.dataset.dive || el.dataset.cat) { S.dive = el.dataset.dive || el.dataset.cat; keep("dive", S.dive); S.tab = "deepdive"; keep("tab", S.tab); render(); window.scrollTo(0, 0); return; }
  const a = el.dataset.action;
  if (a === "reload") load();
  else if (a === "more") { S.shown += 200; render(); }
  else if (a === "taxcsv" && S.tax) downloadTaxCsv();
  else if (a === "feedback") {
    let entry = null;
    if (el.dataset.entry) { const [src, id] = el.dataset.entry.split(":"); entry = S.data.entries.find(e => e.source === src && String(e.entryId) === id); }
    openNote({ kind: el.dataset.kind, section: el.dataset.section, category: el.dataset.category || null, entry });
  }
});
document.addEventListener("change", ev => {
  if (ev.target.dataset?.editEntry) return changeEntry(ev.target);
  if (ev.target.dataset?.editTrigger) return changeTrigger(ev.target);
  const k = ev.target.dataset?.set; if (!k) return;
  const v = ev.target.type === "checkbox" ? ev.target.checked : ev.target.value;
  if (k === "year") { S.year = +v; keep("year", S.year); return load(); }
  if (k === "ytd") { S.ytd = v; keep("ytd", v); return load(); }
  if (k === "taxYear") { S.taxYear = +v; keep("taxYear", S.taxYear); S.tax = null; return render(); }
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
// The Payee and Bought columns' widths: dragged on their headers' grips (mouse or finger), kept in this browser.
const COLUMN_WIDTHS = { payee: 220, bought: 240 };
const setColumnWidth = (column, w) => document.documentElement.style.setProperty(`--${column}-w`, Math.round(Math.min(900, Math.max(80, w))) + "px");
for (const column in COLUMN_WIDTHS) setColumnWidth(column, saved(column + "Width", COLUMN_WIDTHS[column]));
document.addEventListener("pointerdown", ev => {
  const grip = ev.target.closest("[data-resize]"); if (!grip) return;
  ev.preventDefault();
  const column = grip.dataset.resize;
  const startX = ev.clientX, start = grip.parentElement.getBoundingClientRect().width;
  try { grip.setPointerCapture(ev.pointerId); } catch { /* the page's own listeners below follow the pointer anyway */ }
  const move = e => setColumnWidth(column, start + e.clientX - startX);
  const up = () => {
    document.removeEventListener("pointermove", move); document.removeEventListener("pointerup", up); document.removeEventListener("pointercancel", up);
    keep(column + "Width", parseInt(getComputedStyle(document.documentElement).getPropertyValue(`--${column}-w`)));
  };
  document.addEventListener("pointermove", move); document.addEventListener("pointerup", up); document.addEventListener("pointercancel", up);
});
document.addEventListener("dblclick", ev => {
  const column = ev.target.closest("[data-resize]")?.dataset.resize; if (!column) return;
  setColumnWidth(column, COLUMN_WIDTHS[column]); keep(column + "Width", COLUMN_WIDTHS[column]);
});

let resizeTimer;
window.addEventListener("resize", () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(render, 200); });
load();
