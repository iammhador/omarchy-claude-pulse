// Run: node tests/model.test.js
const fs = require("fs"), path = require("path"), assert = require("assert")
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*/, "")
const M = new Function(src + "; return EXPORTS")()

// Theme: named colours win, a pink "orange" is replaced by a yellow/red mix.
const pal = M.parseTheme('green = "#00ff00"\nyellow = "#ffff00"\nred = "#ff0000"\norange = "#f59cb5"\n')
assert.strictEqual(pal.green, "#00ff00")
assert.strictEqual(pal.orange, "#ff8000")
assert.strictEqual(M.parseTheme("").red, "#e06c75")

// Gauge: ends and stops.
assert.strictEqual(M.gaugeColor(0, pal), "#00ff00")
assert.strictEqual(M.gaugeColor(50, pal), "#ffff00")
assert.strictEqual(M.gaugeColor(95, pal), "#ff0000")
assert.strictEqual(M.gaugeColor(250, pal), "#ff0000")
assert.strictEqual(M.level(74), "mid")
assert.strictEqual(M.level(90), "critical")

// Pace: half the window gone, 70% used -> 20 points ahead, runs out early.
const now = 1_800_000_000
const win = { pct: 70, windowSec: 18000, resetsAt: now + 9000 }
const p = M.pace(win, now)
assert.strictEqual(Math.round(p.elapsed), 50)
assert.strictEqual(p.delta, 20)
assert.strictEqual(p.state, "hot")
assert.strictEqual(p.arrow, "↑")
assert.ok(p.runsOutBeforeReset)
assert.strictEqual(M.pace({ pct: 48, windowSec: 18000, resetsAt: now + 9000 }, now).state, "on")
assert.strictEqual(M.pace({ pct: 10, windowSec: 18000, resetsAt: now + 9000 }, now).arrow, "↓")
assert.strictEqual(M.pace({ pct: 10 }, now).state, "unknown")

// forecast: recent rate from saved readings
const ses = { windowSec: 18000, pct: 50, resetsAt: now + 3 * 3600 }
const rising = [[now - 3600, 30], [now - 1800, 40], [now, 50]]   // 20 pts an hour
const fc = M.forecast(rising, ses, now)
assert.strictEqual(Math.round(fc.hitsAt - now), 9000)           // 50 pts left = 2.5 h
assert.strictEqual(fc.beforeReset, true)                         // reset is in 3 h
assert.strictEqual(M.forecast(rising, { ...ses, resetsAt: now + 3600 }, now).beforeReset, false) // resets first
assert.strictEqual(M.forecast([[now - 3600, 20], [now, 50]], { ...ses, resetsAt: now + 3 * 3600 }, now).beforeReset, true) // 30/h: 1h 40m
assert.strictEqual(M.forecast([[now - 3600, 50], [now, 50]], ses, now).beforeReset, false)   // flat
assert.strictEqual(M.forecast([[now, 50]], ses, now), null)                                 // one reading
assert.strictEqual(M.forecast([[now - 120, 49], [now, 50]], ses, now), null)                // under 10 min
assert.strictEqual(M.forecast(rising, { ...ses, pct: 100 }, now), null)                     // used up
assert.strictEqual(M.forecast(undefined, ses, now), null)

// dailyAllowance: weekly only, at least a day left, not used up
const wk = { windowSec: 604800 }
assert.strictEqual(Math.round(M.dailyAllowance({ ...wk, pct: 40, resetsAt: now + 4 * 86400 }, now).perDay), 15)
assert.strictEqual(M.dailyAllowance({ ...wk, pct: 40, resetsAt: now + 4 * 86400 }, now).daysLeft, 4)
assert.strictEqual(M.dailyAllowance({ ...wk, pct: 100, resetsAt: now + 4 * 86400 }, now), null)
assert.strictEqual(M.dailyAllowance({ ...wk, pct: 40, resetsAt: now + 3600 }, now), null)
assert.strictEqual(M.dailyAllowance({ windowSec: 18000, pct: 40, resetsAt: now + 9000 }, now), null)
assert.strictEqual(M.dailyAllowance({ ...wk, pct: 40 }, now), null)
assert.strictEqual(M.dailyAllowance(null, now), null)

// Formatting.
assert.strictEqual(M.duration(59), "59s")
assert.strictEqual(M.duration(5400), "1h 30m")
assert.strictEqual(M.duration(90000), "1d 1h")
assert.strictEqual(M.tokens(950), "950")
assert.strictEqual(M.tokens(1500), "1.5k")
assert.strictEqual(M.tokens(37552478), "38M")
assert.strictEqual(M.tokens(1803218765), "1.80B")
assert.strictEqual(M.cost(0), "$0")
assert.strictEqual(M.cost(0.004), "<$0.01")
assert.strictEqual(M.cost(13.6634), "$13.66")
assert.strictEqual(M.shortPath("/home/u/x", "/home/u"), "~/x")
assert.strictEqual(M.truthy("false", true), false)
assert.strictEqual(M.truthy("", true), true)
assert.strictEqual(M.truthy(true, false), true)

// Sessions: waiting first, longest wait on top.
const s = (pid, status, since, chain) => ({ pid, status, since, chain: chain || [pid] })
const sorted = M.sortSessions([s(1, "busy", 10), s(2, "waiting", 50), s(3, "waiting", 20), s(4, "busy", 30)])
assert.deepStrictEqual(sorted.map(x => x.pid), [3, 2, 4, 1])
assert.strictEqual(M.waitingCount(sorted), 2)
assert.strictEqual(M.windowFor(s(9, "busy", 0, [9, 8, 7]), [{ pid: 7, address: "0xabc" }]), "0xabc")
assert.strictEqual(M.windowFor(s(9, "busy", 0, [9]), [{ pid: 7, address: "0xabc" }]), "")

// Alerts: none at startup; one after the delay; "finished" after a long run; never twice.
let r = M.sessionAlerts({}, [s(1, "waiting", now - 100), s(2, "busy", now - 300)], now)
assert.strictEqual(r.alerts.length, 0)
r = M.sessionAlerts(r.track, [s(1, "waiting", now - 100), s(2, "waiting", now)], now)
assert.strictEqual(r.alerts.length, 0, "inside the delay")
r = M.sessionAlerts(r.track, [s(1, "waiting", now - 100), s(2, "waiting", now)], now + 11)
assert.strictEqual(r.alerts.length, 1)
assert.strictEqual(r.alerts[0].pid, 2)
assert.strictEqual(r.alerts[0].kind, "finished")
r = M.sessionAlerts(r.track, [s(2, "waiting", now)], now + 30)
assert.strictEqual(r.alerts.length, 0, "only once per wait")
r = M.sessionAlerts(r.track, [s(2, "busy", now + 40)], now + 40)
r = M.sessionAlerts(r.track, [s(2, "waiting", now + 45)], now + 60)
assert.strictEqual(r.alerts[0].kind, "waiting")
// The focused terminal gets a quiet alert: the sound plays, no pop-up.
r = M.sessionAlerts(r.track, [s(2, "busy", now + 70, [2, 50])], now + 70)
r = M.sessionAlerts(r.track, [s(2, "waiting", now + 75, [2, 50])], now + 99, { focusedPid: 50 })
assert.strictEqual(r.alerts.length, 1)
assert.strictEqual(r.alerts[0].quiet, true)

// Approvals fire at once (no delay) and only once per tool call.
const ap = (pid, id, kind) => Object.assign(s(pid, "waiting", now + 200), { approval: { id, tool: "Bash", detail: "ls" }, waitKind: kind || "approval" })
let q = M.sessionAlerts({}, [s(7, "busy", now)], now)
q = M.sessionAlerts(q.track, [ap(7, "t1")], now + 200)
assert.strictEqual(q.alerts.length, 1)
assert.strictEqual(q.alerts[0].kind, "approval")
q = M.sessionAlerts(q.track, [ap(7, "t1")], now + 230)
assert.strictEqual(q.alerts.length, 0, "same approval, no repeat")
q = M.sessionAlerts(q.track, [s(7, "busy", now + 240)], now + 240)
q = M.sessionAlerts(q.track, [ap(7, "t2", "question")], now + 241)
assert.strictEqual(q.alerts[0].kind, "question")

// Context alert once past 80%, re-arms below 60%.
const cx = (ctx) => Object.assign(s(8, "busy", now), { model: "claude-opus-5-5", context: ctx })
let c = M.sessionAlerts({}, [cx(500000)], now)
c = M.sessionAlerts(c.track, [cx(820000)], now + 1)
assert.strictEqual(c.alerts[0].kind, "context")
c = M.sessionAlerts(c.track, [cx(900000)], now + 2)
assert.strictEqual(c.alerts.length, 0)
c = M.sessionAlerts(c.track, [cx(100000)], now + 3)
c = M.sessionAlerts(c.track, [cx(850000)], now + 4)
assert.strictEqual(c.alerts.length, 1, "re-armed after a compact")
// A session first seen already past 80% stays quiet.
assert.strictEqual(M.sessionAlerts({}, [Object.assign(cx(950000), { pid: 9 })], now).alerts.length, 0)

// Jobs, labels, modes, folders, cycling, versions.
let jb = M.jobAlerts(null, [{ id: "a", state: "working" }])
assert.strictEqual(jb.alerts.length, 0)
jb = M.jobAlerts(jb.state, [{ id: "a", state: "blocked" }])
assert.strictEqual(jb.alerts[0].kind, "blocked")
assert.strictEqual(M.doingLabel({ tool: "Edit", detail: "Navbar.tsx" }), "Editing Navbar.tsx")
assert.strictEqual(M.doingLabel({ tool: "Bash", detail: "npm test" }), "Running npm test")
assert.strictEqual(M.doingLabel(null), "")
assert.strictEqual(M.waitLabel({ status: "waiting", waitKind: "approval", approval: { tool: "mcp__github__create_pr" } }), "Needs approval · github__create_pr")
assert.strictEqual(M.waitLabel({ status: "waiting", waitKind: "plan" }), "Plan ready to review")
assert.strictEqual(M.waitLabel({ status: "busy" }), "")
assert.strictEqual(M.waitLabel({ status: "waiting", waitKind: "input" }), "Needs your input")
assert.strictEqual(M.modeInfo("bypassPermissions").level, "danger")
assert.strictEqual(M.modeInfo("default").label, "")
assert.notStrictEqual(M.toolGlyph("mcp__x__y"), M.toolGlyph("Unknown"))
const fo = M.orderFolders([{ cwd: "/a", project: "a", last: 5 }, { cwd: "/b", project: "b", last: 4 }], ["/b", "/z/pinned"])
assert.deepStrictEqual(fo.map(f => f.cwd), ["/b", "/z/pinned", "/a"])
assert.deepStrictEqual(fo.map(f => f.pinned), [true, true, false])
assert.strictEqual(fo[1].project, "pinned")
const ws = [s(1, "waiting", 1), s(2, "busy", 1), s(3, "waiting", 1)]
assert.strictEqual(M.nextWaiting(ws, 0).pid, 1)
assert.strictEqual(M.nextWaiting(ws, 1).pid, 3)
assert.strictEqual(M.nextWaiting(ws, 3).pid, 1)
assert.strictEqual(M.nextWaiting([s(2, "busy", 1)], 0), null)
assert.ok(M.versionNewer("2.1.330", "2.1.322"))
assert.ok(!M.versionNewer("2.1.322", "2.1.322"))
assert.ok(M.versionNewer("2.10.0", "2.9.9"))

// Limit alerts: first sight silent, crossing up fires the highest threshold, reset fires.
let l = M.limitAlerts({}, [{ id: "session", pct: 60 }])
assert.strictEqual(l.alerts.length, 0)
l = M.limitAlerts(l.state, [{ id: "session", pct: 92 }])
assert.strictEqual(l.alerts[0].threshold, 90)
l = M.limitAlerts(l.state, [{ id: "session", pct: 93 }])
assert.strictEqual(l.alerts.length, 0)
l = M.limitAlerts(l.state, [{ id: "session", pct: 2 }])
assert.strictEqual(l.alerts[0].kind, "reset")

// Bar window and the "other limit" dot.
const bw = M.barWindow([{ id: "session", pct: 10 }, { id: "weekly", pct: 60 }, { id: "model:Fable", pct: 95 }], "session")
assert.strictEqual(bw.main.id, "session")
assert.strictEqual(bw.worst.id, "model:Fable")

// History search: every word must match somewhere; live sessions are hidden.
const recent = [{ sessionId: "a", title: "Fix navbar", project: "acme", prompt: "mobile menu" },
                { sessionId: "b", title: "Deploy", project: "atlas", prompt: "vercel" }]
assert.deepStrictEqual(M.filterRecent(recent, "acme menu").map(x => x.sessionId), ["a"])
assert.deepStrictEqual(M.filterRecent(recent, "", { a: true }).map(x => x.sessionId), ["b"])
assert.deepStrictEqual(M.chartBars([{ cost: 5 }, { cost: 10 }]).map(b => b.ratio), [0.5, 1])

// Identity: stable, theme-driven, letters and model families.
const full = M.parseTheme('blue = "#0000ff"\nmagenta = "#ff00ff"\ncyan = "#00ffff"\n')
assert.strictEqual(full.blue, "#0000ff")
assert.strictEqual(M.projectColor("Acme Storefront", full), M.projectColor("Acme Storefront", full))
const colours = new Set(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"].map(n => M.projectColor(n, full)))
assert.ok(colours.size >= 3, "names spread over the palette")
assert.strictEqual(M.projectLetter("~"), "~")
assert.strictEqual(M.projectLetter("roy software"), "R")
assert.strictEqual(M.projectLetter("_9lives"), "9")
assert.strictEqual(M.modelFamily("Opus 5.5"), "opus")
assert.strictEqual(M.modelFamily("claude-mythos-5-2"), "fable")
assert.strictEqual(M.modelFamily("gpt"), "other")
assert.strictEqual(M.modelColor("Fable 5.2", full), "#ff00ff")
const sp = M.sparkPoints([0, 5, 10])
assert.deepStrictEqual(sp.map(p => p.y), [0, 0.5, 1])
assert.deepStrictEqual(sp.map(p => p.x), [0, 0.5, 1])
assert.deepStrictEqual(M.sparkPoints([0, 0]).map(p => p.y), [0, 0])

// Claude palette: dark by default, light from the theme's mode; coral mark warms as it fills.
assert.strictEqual(M.parseTheme('mode = "light"\n').mode, "light")
assert.strictEqual(M.parseTheme("").mode, "dark")
const cd = M.claudePalette("dark"), cl = M.claudePalette("light")
assert.strictEqual(cd.accent, "#d97757")
assert.strictEqual(cl.bg, "#faf9f5")
cd.accent = "#000000"
assert.strictEqual(M.claudePalette("dark").accent, "#d97757", "a copy, not the shared table")
assert.strictEqual(M.claudeMark(10, cl), cl.accent)
assert.strictEqual(M.claudeMark(95, cl), cl.red)
assert.notStrictEqual(M.claudeMark(80, cl), cl.accent)
assert.strictEqual(M.modelColor("Opus 5.5", cl), cl.clay)
assert.notStrictEqual(M.modelColor("Opus 5.5", cl), cl.accent, "coral stays Claude's")

// Claude scheme: project colours never use the coral accent or the alert red.
const cp = M.claudePalette("dark")
for (const n of ["Atlas API", "Portfolio Site", "Acme Storefront", "~", "Infra Tools"]) {
  const c = M.projectColor(n, cp)
  assert.ok(cp.projects.includes(c) && c !== cp.accent && c !== cp.red, n)
}

// Alert cards: tone, button and stickiness per kind.
assert.deepStrictEqual([M.cardSpec({ kind: "finished", ranFor: 240 }).headline, M.cardSpec({ kind: "finished" }).tone], ["Finished in 4m", "sage"])
assert.strictEqual(M.cardSpec({ kind: "approval" }).sticky, true)
assert.strictEqual(M.cardSpec({ kind: "approval" }).tone, "red")
assert.strictEqual(M.cardSpec({ kind: "question" }).button, "Answer")
assert.strictEqual(M.cardSpec({ kind: "plan" }).button, "Review")
assert.strictEqual(M.cardSpec({ kind: "waiting" }).sticky, false)
assert.strictEqual(M.cardSpec({ kind: "jobdone", job: { sessionId: "x" } }).button, "Resume")
assert.strictEqual(M.cardSpec({ kind: "jobblocked", job: {} }).button, "")
assert.strictEqual(M.cardSpec({ kind: "limit", threshold: 90, window: { label: "Weekly", pct: 91.2 } }).headline, "Weekly at 91%")
assert.strictEqual(M.cardSpec({ kind: "limit", threshold: 75, window: { label: "Session", pct: 76 } }).tone, "amber")
assert.strictEqual(M.cardSpec({ kind: "?", title: "Hi" }).headline, "Hi")
const log = Array.from({ length: 60 }, (_, i) => ({ id: i, ts: i }))
assert.strictEqual(M.trimLog(log, 50).length, 50)
assert.strictEqual(M.trimLog(log, 50)[0].id, 59)

console.log("model tests: ok")
