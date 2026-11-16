.pragma library

// Claude Pulse: pure logic, shared by BarWidget.qml and tests/model.test.js.
// No Qt here: plain functions over plain data, so node can test them.

var DEFAULT_PALETTE = { green: "#98c379", yellow: "#e5c07b", orange: "#d19a66", red: "#e06c75",
                        cyan: "#56b6c2", blue: "#61afef", magenta: "#c678dd" }

// ---------------------------------------------------------------- Claude palette
//
// Claude's own look: warm charcoal and ivory surfaces, cream text, and the
// coral/terracotta accent. The gauge and identity colours are warm and earthy
// to sit with it (sage, ochre, coral, brick; slate, plum, teal).
var CLAUDE = {
  dark: {
    bg: "#262624", surface: "#30302e", fg: "#faf9f5", dim: "#c2c0b6", faint: "#8a8880",
    accent: "#d97757", accentDeep: "#c6613f", urgent: "#e25d4f", onAccent: "#1f1e1d",
    green: "#8db07a", yellow: "#e3b56a", orange: "#d97757", red: "#e25d4f",
    cyan: "#6fa8a0", blue: "#7f9fc9", magenta: "#b483aa", clay: "#b8a28c", mode: "dark",
    projects: ["#7f9fc9", "#b483aa", "#6fa8a0", "#8db07a", "#d1a85e", "#c9b28c", "#c98f8f", "#93a0b4"]
  },
  light: {
    bg: "#faf9f5", surface: "#f0eee6", fg: "#141413", dim: "#3d3d3a", faint: "#87867f",
    accent: "#c6613f", accentDeep: "#a94f30", urgent: "#c2412f", onAccent: "#ffffff",
    green: "#5f8a4e", yellow: "#b8862b", orange: "#c6613f", red: "#c2412f",
    cyan: "#3f8079", blue: "#4f74a3", magenta: "#8e5585", clay: "#7d6650", mode: "light",
    projects: ["#4f74a3", "#8e5585", "#3f8079", "#5f8a4e", "#a57a26", "#8a7550", "#a35d5d", "#5d6b80"]
  }
}

function claudePalette(mode) {
  var src = CLAUDE[mode === "light" ? "light" : "dark"]
  var out = {}
  for (var k in src) out[k] = Array.isArray(src[k]) ? src[k].slice() : src[k]
  return out
}

// The bar mark in Claude's coral, warming to amber and red only as a limit fills.
function claudeMark(pct, pal) {
  var p = Number(pct) || 0
  return p >= 90 ? pal.red : p >= 75 ? mix(pal.accent, pal.yellow, 0.55) : pal.accent
}

// ---------------------------------------------------------------- theme

// Omarchy's colors.toml: `key = "#rrggbb"` lines. Missing keys keep defaults.
function parseTheme(text) {
  var pal = {}
  for (var k in DEFAULT_PALETTE) pal[k] = DEFAULT_PALETTE[k]
  var seen = {}
  pal.mode = /^\s*mode\s*=\s*"light"/m.test(String(text || "")) ? "light" : "dark"
  String(text || "").split("\n").forEach(function(line) {
    var m = /^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6})"/.exec(line)
    if (m && pal.hasOwnProperty(m[1])) { pal[m[1]] = m[2].toLowerCase(); seen[m[1]] = true }
  })
  // Some themes have no real orange (or reuse a pink); derive it from yellow and red.
  if (!seen.orange || hue(pal.orange) > 300 || hue(pal.orange) < 10) pal.orange = mix(pal.yellow, pal.red, 0.5)
  return pal
}

function rgb(hex) {
  var h = String(hex).replace("#", "")
  return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)]
}

function hex(c) {
  return "#" + c.map(function(v) {
    var s = Math.max(0, Math.min(255, Math.round(v))).toString(16)
    return s.length < 2 ? "0" + s : s
  }).join("")
}

function hue(h) {
  var c = rgb(h).map(function(v) { return v / 255 })
  var max = Math.max(c[0], c[1], c[2]), min = Math.min(c[0], c[1], c[2]), d = max - min
  if (d === 0) return 0
  var out
  if (max === c[0]) out = ((c[1] - c[2]) / d) % 6
  else if (max === c[1]) out = (c[2] - c[0]) / d + 2
  else out = (c[0] - c[1]) / d + 4
  out *= 60
  return out < 0 ? out + 360 : out
}

function mix(a, b, t) {
  var x = rgb(a), y = rgb(b)
  return hex([x[0] + (y[0] - x[0]) * t, x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t])
}

// A thermometer: green at 0, yellow at 50, orange at 75, red from 90.
function gaugeColor(pct, pal) {
  pal = pal || DEFAULT_PALETTE
  var p = Math.max(0, Math.min(100, Number(pct) || 0))
  var stops = [[0, pal.green], [50, pal.yellow], [75, pal.orange], [90, pal.red], [100, pal.red]]
  for (var i = 1; i < stops.length; i++) {
    if (p <= stops[i][0]) {
      var a = stops[i - 1], b = stops[i]
      return mix(a[1], b[1], (p - a[0]) / Math.max(1, b[0] - a[0]))
    }
  }
  return pal.red
}

function level(pct) {
  var p = Number(pct) || 0
  return p >= 90 ? "critical" : p >= 75 ? "high" : p >= 50 ? "mid" : "low"
}

// ---------------------------------------------------------------- identity

// A stable colour per project, from the theme, so a project looks the same
// in every tab. FNV-1a hash of the name picks the slot.
var PROJECT_SLOTS = ["blue", "magenta", "cyan", "green", "orange", "yellow", "red"]
function projectColor(name, pal) {
  pal = pal || DEFAULT_PALETTE
  var h = 2166136261
  var s = String(name || "")
  for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul ? Math.imul(h, 16777619) : (h * 16777619) | 0 }
  // A palette may bring its own identity colours (Claude's keeps coral for itself).
  if (pal.projects && pal.projects.length) return pal.projects[Math.abs(h) % pal.projects.length]
  return pal[PROJECT_SLOTS[Math.abs(h) % PROJECT_SLOTS.length]]
}

function projectLetter(name) {
  var s = String(name || "").trim()
  if (s === "" || s === "~") return "~"
  var m = /[A-Za-z0-9]/.exec(s)
  return m ? m[0].toUpperCase() : s.charAt(0)
}

function modelFamily(name) {
  var m = /(fable|mythos|opus|sonnet|haiku)/i.exec(String(name || ""))
  if (!m) return "other"
  var f = m[1].toLowerCase()
  return f === "mythos" ? "fable" : f
}

function modelColor(name, pal) {
  pal = pal || DEFAULT_PALETTE
  var f = modelFamily(name)
  // Coral belongs to Claude itself and to "needs you", so Opus gets a calm clay.
  return f === "fable" ? pal.magenta : f === "opus" ? (pal.clay || pal.cyan) : f === "sonnet" ? pal.blue : f === "haiku" ? pal.green : pal.cyan
}

// Sparkline points, x and y in 0..1 (y = 0 at the bottom).
function sparkPoints(buckets) {
  var b = buckets || []
  var max = 0
  for (var i = 0; i < b.length; i++) if (b[i] > max) max = b[i]
  var n = Math.max(1, b.length - 1)
  return b.map(function(v, i) { return { x: i / n, y: max > 0 ? v / max : 0 } })
}

// ---------------------------------------------------------------- pace

// How far ahead of an even burn rate a window is. delta is in percentage
// points: usage minus the share of the window that has passed.
function pace(win, now, tolerance) {
  var tol = tolerance === undefined ? 5 : tolerance
  var span = Number(win.windowSec) || 0
  var left = Math.max(0, (Number(win.resetsAt) || 0) - now)
  if (!span || !win.resetsAt) return { elapsed: 0, delta: 0, arrow: "", state: "unknown" }
  var elapsed = Math.max(0, Math.min(100, (1 - left / span) * 100))
  var delta = Math.round((Number(win.pct) || 0) - elapsed)
  var state = delta > 15 ? "hot" : delta > tol ? "ahead" : delta < -tol ? "under" : "on"
  var arrow = state === "hot" || state === "ahead" ? "↑" : state === "under" ? "↓" : "→"
  // At this burn rate, when would it run out?
  var eta = 0
  var used = Number(win.pct) || 0
  if (used > 0 && elapsed > 0 && used < 100) {
    var perSec = used / ((elapsed / 100) * span)
    eta = (100 - used) / perSec
  }
  return { elapsed: elapsed, delta: delta, arrow: arrow, state: state, runsOutIn: eta, runsOutBeforeReset: eta > 0 && eta < left }
}

// For a weekly window: how many points a day you can spend and still last
// until the reset. Null when it does not apply (not weekly, used up, or less
// than a day left, where the reset countdown says it better).
function dailyAllowance(win, now) {
  if (!win || Number(win.windowSec) !== 604800 || !win.resetsAt) return null
  var used = Number(win.pct) || 0
  var days = ((Number(win.resetsAt) || 0) - now) / 86400
  if (used >= 100 || days < 1) return null
  return { perDay: (100 - used) / days, daysLeft: days }
}

// ---------------------------------------------------------------- formatting

function duration(sec) {
  var s = Math.max(0, Math.round(Number(sec) || 0))
  if (s < 60) return s + "s"
  var m = Math.floor(s / 60)
  if (m < 60) return m + "m"
  var h = Math.floor(m / 60)
  if (h < 24) return h + "h " + (m % 60) + "m"
  var d = Math.floor(h / 24)
  return d + "d " + (h % 24) + "h"
}

function tokens(n) {
  var v = Number(n) || 0
  if (v < 1000) return String(Math.round(v))
  if (v < 1e6) return (v / 1e3).toFixed(v < 1e4 ? 1 : 0) + "k"
  if (v < 1e9) return (v / 1e6).toFixed(v < 1e7 ? 1 : 0) + "M"
  return (v / 1e9).toFixed(2) + "B"
}

function cost(x) {
  var v = Number(x) || 0
  if (v === 0) return "$0"
  if (v < 0.01) return "<$0.01"
  if (v < 100) return "$" + v.toFixed(2)
  return "$" + Math.round(v).toLocaleString()
}

function ago(ts, now) {
  var s = Math.max(0, now - (Number(ts) || 0))
  if (s < 45) return "now"
  return duration(s) + " ago"
}

function shortPath(path, home) {
  var p = String(path || "")
  if (home && p.indexOf(home) === 0) p = "~" + p.slice(home.length)
  return p
}

// Context window bar: models here have 1M context; older ones 200k.
function contextLimit(model) {
  return /haiku-4/.test(String(model || "")) ? 200000 : 1000000
}

// ---------------------------------------------------------------- sessions

// Waiting sessions first (longest wait on top), then busy ones (newest first).
function sortSessions(list) {
  return (list || []).slice().sort(function(a, b) {
    if (a.status !== b.status) return a.status === "waiting" ? -1 : 1
    return a.status === "waiting" ? a.since - b.since : b.since - a.since
  })
}

function waitingCount(list) {
  return (list || []).filter(function(s) { return s.status === "waiting" }).length
}

function busyCount(list) {
  return (list || []).filter(function(s) { return s.status === "busy" }).length
}

// Find the Hyprland window for a session: the first PID in its ancestry that
// owns a window. `windows` = [{pid, address}].
function windowFor(session, windows) {
  var byPid = {}
  ;(windows || []).forEach(function(w) { if (w.pid) byPid[w.pid] = w.address })
  var chain = session && session.chain || []
  for (var i = 0; i < chain.length; i++) if (byPid[chain[i]]) return byPid[chain[i]]
  return ""
}

// Track transitions between polls and decide which alerts fire.
// track: {pid: {...}}. Returns {track, alerts}. Kinds:
//   approval / question / plan: blocked on you, fire at once
//   finished / waiting: stopped, fire after `delay` seconds
//   context: context crossed `contextPct` (re-arms below 60%)
// Nothing fires for a session first seen already waiting (startup). The
// pop-up is marked `quiet` for the focused terminal; sounds still play.
function sessionAlerts(track, sessions, now, opts) {
  opts = opts || {}
  var delay = opts.delay === undefined ? 10 : opts.delay
  var longBusy = opts.longBusy === undefined ? 120 : opts.longBusy
  var ctxPct = opts.contextPct === undefined ? 80 : opts.contextPct
  var focused = opts.focusedPid || 0
  var next = {}, alerts = []
  ;(sessions || []).forEach(function(s) {
    var prev = track ? track[s.pid] : null
    var t = prev ? { status: prev.status, busySince: prev.busySince, waitSince: prev.waitSince, alerted: prev.alerted,
                     armed: prev.armed, approvalId: prev.approvalId, ctxArmed: prev.ctxArmed }
                 : { status: s.status, busySince: s.status === "busy" ? s.since : 0, waitSince: s.status === "waiting" ? s.since : 0,
                     alerted: true, armed: false, approvalId: s.approval ? s.approval.id : "", ctxArmed: !!prev }
    var isFocused = !!focused && (s.chain || []).indexOf(focused) >= 0
    if (prev && prev.status !== s.status) {
      if (s.status === "busy") { t.busySince = s.since || now; t.alerted = false; t.armed = true }
      else { t.waitSince = s.since || now; t.alerted = false; t.armed = true }
    }
    t.status = s.status
    var ranFor = t.busySince && t.waitSince > t.busySince ? t.waitSince - t.busySince : 0
    // Blocked on a permission prompt, a question or a plan: say so at once.
    var ap = s.status === "waiting" ? s.approval : null
    if (ap && ap.id && ap.id !== t.approvalId && prev) {
      t.approvalId = ap.id
      t.alerted = true
      alerts.push({ pid: s.pid, kind: s.waitKind || "approval", ranFor: ranFor, quiet: isFocused, session: s })
    } else if (!ap) {
      t.approvalId = ""
    }
    if (s.status === "waiting" && t.armed && !t.alerted && now - t.waitSince >= delay) {
      t.alerted = true
      alerts.push({ pid: s.pid, kind: ranFor >= longBusy ? "finished" : "waiting", ranFor: ranFor, quiet: isFocused, session: s })
    }
    // Context window filling up.
    var limit = contextLimit(s.model)
    var pct = limit ? 100 * (s.context || 0) / limit : 0
    if (prev === null || prev === undefined) t.ctxArmed = pct < ctxPct
    if (t.ctxArmed && pct >= ctxPct) {
      t.ctxArmed = false
      alerts.push({ pid: s.pid, kind: "context", pct: Math.round(pct), quiet: false, session: s })
    } else if (!t.ctxArmed && pct < 60) {
      t.ctxArmed = true
    }
    next[s.pid] = t
  })
  return { track: next, alerts: alerts }
}

// Background jobs: state changes worth a notification. First sight is silent.
function jobAlerts(prev, jobs) {
  var next = {}, alerts = []
  ;(jobs || []).forEach(function(j) {
    next[j.id] = j.state
    if (!prev || prev[j.id] === undefined || prev[j.id] === j.state) return
    if (/^(done|completed|finished|blocked|failed|error)$/i.test(j.state)) alerts.push({ kind: j.state.toLowerCase(), job: j })
  })
  return { state: next, alerts: alerts }
}

// ---------------------------------------------------------------- alert cards

// How a card looks and behaves for each alert kind.
//   tone: sage / coral / red / amber / neutral   (mapped to colours in QML)
//   button: the main action's label ("" = none); sticky: stays until handled
function cardSpec(a) {
  a = a || {}
  var k = String(a.kind || "")
  var s = a.session || {}
  var j = a.job || {}
  switch (k) {
  case "finished": return { headline: "Finished" + (a.ranFor ? " in " + duration(a.ranFor) : ""), tone: "sage", button: "Go to terminal", sticky: false, glyph: "\u{f012c}" }
  case "waiting": return { headline: "Waiting for you", tone: "coral", button: "Go to terminal", sticky: false, glyph: "\u{f0e1e}" }
  case "approval": return { headline: "Needs approval", tone: "red", button: "Go to terminal", sticky: true, glyph: "\u{f0026}" }
  case "input": return { headline: "Needs your input", tone: "red", button: "Go to terminal", sticky: true, glyph: "\u{f0026}" }
  case "question": return { headline: "Asking you a question", tone: "coral", button: "Answer", sticky: true, glyph: "\u{f02d7}" }
  case "plan": return { headline: "Plan ready to review", tone: "coral", button: "Review", sticky: true, glyph: "\u{f0bdd}" }
  case "context": return { headline: "Context " + (a.pct || "") + "%", tone: "amber", button: "Go to terminal", sticky: false, glyph: "\u{f0026}" }
  case "jobdone": return { headline: "Background job done", tone: "sage", button: j.sessionId ? "Resume" : "", sticky: false, glyph: "\u{f012c}" }
  case "jobblocked": return { headline: "Background job " + (j.state || "blocked"), tone: "red", button: j.sessionId ? "Resume" : "", sticky: false, glyph: "\u{f0026}" }
  case "limit": return { headline: (a.window ? a.window.label : "Limit") + " at " + Math.round(a.window ? a.window.pct : 0) + "%", tone: a.threshold >= 90 ? "red" : "amber", button: "", sticky: false, glyph: "\u{f029a}" }
  case "reset": return { headline: (a.window ? a.window.label : "Limit") + " reset", tone: "sage", button: "", sticky: false, glyph: "\u{f029a}" }
  case "mcp": return { headline: "MCP needs sign-in", tone: "red", button: "", sticky: false, glyph: "\u{f048b}" }
  case "login": return { headline: "Sign-in ending", tone: a.expired ? "red" : "amber", button: "", sticky: false, glyph: "\u{f0306}" }
  default: return { headline: a.title || "Claude Pulse", tone: "neutral", button: "", sticky: false, glyph: "\u{f02fc}" }
  }
}

// Keep the newest `max` log entries (newest first).
function trimLog(list, max) {
  var l = (list || []).slice().sort(function(x, y) { return (y.ts || 0) - (x.ts || 0) })
  return l.slice(0, max || 50)
}

// ---------------------------------------------------------------- labels

var TOOL_GLYPHS = {
  Bash: "\u{f018d}", Edit: "\u{f03eb}", MultiEdit: "\u{f03eb}", Write: "\u{f0224}", Read: "\u{f0208}",
  NotebookEdit: "\u{f082e}", Grep: "\u{f0349}", Glob: "\u{f0349}", WebFetch: "\u{f059f}", WebSearch: "\u{f059f}",
  Agent: "\u{f0645}", Task: "\u{f0645}", Skill: "\u{f0e7c}", AskUserQuestion: "\u{f02d7}", ExitPlanMode: "\u{f0bdd}",
  TodoWrite: "\u{f0c9e}"
}
function toolGlyph(tool) {
  var t = String(tool || "")
  if (TOOL_GLYPHS[t]) return TOOL_GLYPHS[t]
  return t.indexOf("mcp__") === 0 ? "\u{f048b}" : "\u{f0ad7}"
}

var TOOL_VERBS = {
  Bash: "Running", Edit: "Editing", MultiEdit: "Editing", Write: "Writing", Read: "Reading", NotebookEdit: "Editing",
  Grep: "Searching", Glob: "Finding", WebFetch: "Fetching", WebSearch: "Searching the web for", Agent: "Subagent:",
  Task: "Subagent:", Skill: "Using skill", AskUserQuestion: "Asking", ExitPlanMode: "Planning", TodoWrite: "Updating tasks"
}
function doingLabel(d) {
  if (!d || !d.tool) return ""
  var t = String(d.tool)
  var verb = TOOL_VERBS[t] || (t.indexOf("mcp__") === 0 ? "Calling" : "Using " + t)
  return d.detail ? verb + " " + d.detail : verb
}

function waitLabel(s) {
  if (!s || s.status !== "waiting") return ""
  var k = s.waitKind || "idle"
  if (k === "approval") return "Needs approval" + (s.approval && s.approval.tool ? " · " + s.approval.tool.replace(/^mcp__/, "") : "")
  if (k === "question") return "Asking you a question"
  if (k === "plan") return "Plan ready to review"
  if (k === "input") return "Needs your input"
  return "Waiting for you"
}

// Permission mode: label and severity (none / info / warn / danger).
function modeInfo(mode) {
  var m = String(mode || "")
  if (m === "bypassPermissions") return { label: "bypass", level: "danger" }
  if (m === "auto") return { label: "auto", level: "warn" }
  if (m === "acceptEdits") return { label: "accept edits", level: "warn" }
  if (m === "plan") return { label: "plan", level: "info" }
  if (m === "dontAsk") return { label: "don't ask", level: "warn" }
  return { label: "", level: "none" }
}

// ---------------------------------------------------------------- folders, cycling, versions

// Pinned folders first (in pin order, even if not recent), then recent ones.
function orderFolders(recent, pins) {
  var out = [], seen = {}
  ;(pins || []).forEach(function(cwd) {
    if (!cwd || seen[cwd]) return
    seen[cwd] = true
    var name = cwd === "" ? "?" : cwd.replace(/\/+$/, "").split("/").pop()
    var hit = (recent || []).filter(function(f) { return f.cwd === cwd })[0]
    out.push({ cwd: cwd, project: hit ? hit.project : name, last: hit ? hit.last : 0, pinned: true })
  })
  ;(recent || []).forEach(function(f) {
    if (seen[f.cwd]) return
    seen[f.cwd] = true
    out.push({ cwd: f.cwd, project: f.project, last: f.last, pinned: false })
  })
  return out
}

// The next waiting session after `lastPid`, round-robin.
function nextWaiting(sessions, lastPid) {
  var w = (sessions || []).filter(function(s) { return s.status === "waiting" })
  if (!w.length) return null
  for (var i = 0; i < w.length; i++) if (w[i].pid === lastPid) return w[(i + 1) % w.length]
  return w[0]
}

function versionNewer(a, b) {
  var x = String(a || "").match(/\d+/g) || [], y = String(b || "").match(/\d+/g) || []
  for (var i = 0; i < Math.max(x.length, y.length); i++) {
    var p = Number(x[i] || 0), q = Number(y[i] || 0)
    if (p !== q) return p > q
  }
  return false
}

// ---------------------------------------------------------------- usage alerts

// Crossing 75% / 90% upward, and a reset (big drop), per window id.
// state: {id: lastPct}. First sight never alerts.
function limitAlerts(state, windows, thresholds) {
  var th = thresholds || [75, 90]
  var next = {}, alerts = []
  ;(windows || []).forEach(function(w) {
    var p = Number(w.pct) || 0
    var before = state ? state[w.id] : undefined
    next[w.id] = p
    if (before === undefined) return
    if (p + 20 < before && before >= 50) { alerts.push({ kind: "reset", window: w }); return }
    for (var i = th.length - 1; i >= 0; i--) {
      if (before < th[i] && p >= th[i]) { alerts.push({ kind: "limit", threshold: th[i], window: w }); break }
    }
  })
  return { state: next, alerts: alerts }
}

// The window shown on the bar, and the worst *other* window for the dot.
function barWindow(windows, which) {
  var list = windows || []
  var main = null
  for (var i = 0; i < list.length; i++) if (list[i].id === which) main = list[i]
  if (!main) main = list[0] || null
  var worst = null
  list.forEach(function(w) { if (w !== main && (!worst || w.pct > worst.pct)) worst = w })
  return { main: main, worst: worst }
}

// ---------------------------------------------------------------- history

function matches(row, q) {
  var needle = String(q || "").trim().toLowerCase()
  if (!needle) return true
  var hay = [row.title, row.prompt, row.project, row.cwd, row.branch, row.model].join(" ").toLowerCase()
  return needle.split(/\s+/).every(function(w) { return hay.indexOf(w) >= 0 })
}

function filterRecent(list, q, liveIds) {
  var live = liveIds || {}
  return (list || []).filter(function(r) { return !live[r.sessionId] && matches(r, q) })
}

// Bars for the 7-day chart, scaled to the busiest day.
function chartBars(chart) {
  var max = 0
  ;(chart || []).forEach(function(c) { if (c.cost > max) max = c.cost })
  return (chart || []).map(function(c) { return { label: c.label, cost: c.cost, tokens: c.tokens, ratio: max > 0 ? c.cost / max : 0 } })
}

// `omarchy bar set` stores strings: "false", "0", "off" mean false.
function truthy(v, fallback) {
  if (v === undefined || v === null || v === "") return fallback
  if (typeof v === "string") return !/^(false|0|no|off)$/i.test(v.trim())
  return !!v
}

var EXPORTS = {
  parseTheme: parseTheme, mix: mix, gaugeColor: gaugeColor, level: level, pace: pace, dailyAllowance: dailyAllowance,
  duration: duration, tokens: tokens, cost: cost, ago: ago, shortPath: shortPath, contextLimit: contextLimit,
  sortSessions: sortSessions, waitingCount: waitingCount, busyCount: busyCount, windowFor: windowFor,
  sessionAlerts: sessionAlerts, limitAlerts: limitAlerts, barWindow: barWindow,
  matches: matches, filterRecent: filterRecent, chartBars: chartBars, truthy: truthy, hue: hue,
  claudePalette: claudePalette, claudeMark: claudeMark, projectColor: projectColor,
  jobAlerts: jobAlerts, cardSpec: cardSpec, trimLog: trimLog, toolGlyph: toolGlyph, doingLabel: doingLabel, waitLabel: waitLabel, modeInfo: modeInfo,
  orderFolders: orderFolders, nextWaiting: nextWaiting, versionNewer: versionNewer, projectLetter: projectLetter, modelFamily: modelFamily, modelColor: modelColor, sparkPoints: sparkPoints
}
