// Claude Pulse: Claude Code at a glance in the Omarchy bar.
//
// Bar:   the Claude mark coloured on a usage gauge, the session (or weekly)
//        percentage, and a count of sessions waiting for you. It breathes
//        while Claude works and pulses when a session needs you.
// Panel: a summary strip (session ring, weekly, today, pace, sessions) over
//        five tabs: Live sessions (model, tokens, cost, subagents, context,
//        activity, jump to the terminal), plan Usage, Stats, History (search,
//        resume, start new) and Setup (plugins, skills, MCP servers).
//
// Data comes from bin/claude-pulse-helper, which reads Claude Code's local
// files and the OAuth usage endpoint. It never writes Claude Code's files.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.iammhador.claude-pulse"

  // ---------------------------------------------------------------- settings

  function flag(name, fallback) { return Model.truthy(setting(name, fallback), fallback) }
  function bounded(name, fallback, lo, hi) {
    var n = Math.floor(Number(setting(name, fallback)))
    return isFinite(n) ? Math.max(lo, Math.min(hi, n)) : fallback
  }

  readonly property string barWhich: String(setting("barWindow", "session")).toLowerCase() === "weekly" ? "weekly" : "session"
  readonly property bool showPercent: flag("showPercent", true)
  readonly property bool showWaiting: flag("showWaitingCount", true)
  readonly property bool pulseOn: flag("pulse", true)
  readonly property bool colorBar: flag("colorBar", true)
  readonly property bool contextual: flag("contextual", false)
  readonly property int pollMs: bounded("pollMs", 1500, 750, 10000)
  readonly property int usageSec: bounded("usageIntervalSec", 300, 300, 3600)
  readonly property bool alertWaiting: flag("alertWaiting", true)
  readonly property int waitingDelay: bounded("waitingDelaySec", 10, 0, 600)
  readonly property int longBusy: bounded("finishedAfterSec", 120, 10, 3600)
  readonly property bool alertLimits: flag("alertLimits", true)
  readonly property bool statusCheck: flag("statusCheck", true)
  readonly property bool showCost: flag("costEstimates", true)
  // "claude" (default): Claude's own warm palette. "theme": follow the Omarchy theme.
  readonly property bool claudeScheme: String(setting("colorScheme", "claude")).toLowerCase() !== "theme"
  readonly property bool soundsOn: flag("sounds", true)
  readonly property string soundFinished: String(setting("soundFinished", "claude"))
  readonly property string soundNeedsYou: String(setting("soundNeedsYou", "claude"))
  readonly property string soundWarning: String(setting("soundWarning", "claude"))
  readonly property int soundVolume: bounded("soundVolume", 70, 0, 100)
  readonly property bool alertContext: flag("alertContext", true)
  readonly property int contextWarnPct: bounded("contextWarnPct", 80, 50, 99)
  readonly property bool alertJobs: flag("alertJobs", true)
  readonly property string editor: String(setting("editor", "auto")).toLowerCase()

  // ---------------------------------------------------------------- state

  readonly property string home: Quickshell.env("HOME")
  readonly property string helper: Qt.resolvedUrl("bin/claude-pulse-helper").toString().replace("file://", "")

  property var sessions: []
  property var usage: ({ windows: [], breakdown: [], extra: null, plan: "", updatedAt: 0, stale: false, error: "" })
  property var stats: null
  property var status: ({ indicator: "none", description: "", incidents: [], degraded: [] })
  property var inventory: null
  property var themePal: Model.parseTheme("")
  readonly property var pal: claudeScheme ? Model.claudePalette(themePal.mode) : themePal
  property real now: Date.now() / 1000

  property var sessionTrack: ({})
  property var limitState: ({})
  property bool usagePrimed: false

  property var jobs: []
  property var jobState: null
  property var version: ({ local: "", latest: "", update: false })
  property var health: ({ signedIn: true, tokenExpiresAt: 0, refreshExpiresAt: 0, mcpNeedsAuth: [] })
  property var pins: []
  property bool pinsReady: false
  property string pinsSaved: ""
  property int lastCycledPid: 0
  property real loginWarnedAt: 0

  readonly property int approvals: sessions.filter(function(s) { return s.status === "waiting" && !!s.approval }).length
  readonly property bool healthIssue: version.update || (health.mcpNeedsAuth || []).length > 0 || loginDaysLeft < 3
  readonly property real loginDaysLeft: health.refreshExpiresAt ? (health.refreshExpiresAt - now) / 86400 : 99
  readonly property var folders: Model.orderFolders(stats ? stats.folders : [], pins)

  // Launcher
  property bool launcherOpen: false
  property string launchCwd: ""

  readonly property int waiting: Model.waitingCount(sessions)
  readonly property int busy: Model.busyCount(sessions)
  readonly property var bw: Model.barWindow(usage.windows, barWhich)
  readonly property var mainWin: bw.main
  readonly property var sessionWin: Model.barWindow(usage.windows, "session").main
  readonly property var weeklyWin: {
    var w = usage.windows || []
    for (var i = 0; i < w.length; i++) if (w[i].id === "weekly") return w[i]
    return null
  }
  readonly property bool otherCritical: bw.worst !== null && bw.worst.pct >= 90
  readonly property bool incident: status.indicator !== "none" && status.indicator !== "unknown" && status.indicator !== ""
  readonly property var liveIds: {
    var m = {}
    for (var i = 0; i < sessions.length; i++) m[sessions[i].sessionId] = true
    return m
  }

  // ---------------------------------------------------------------- panel state

  property bool popupOpen: false
  property int tab: 0                       // 0 live, 1 usage, 2 stats, 3 history, 4 setup
  readonly property var tabNames: ["live", "usage", "stats", "history", "setup"]
  property int selected: -1
  property string query: ""
  readonly property var historyRows: stats ? Model.filterRecent(stats.recent, query, liveIds).slice(0, 80) : []

  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }
  function toggle() { popupOpen = !popupOpen }
  function openTab(name) {
    var i = tabNames.indexOf(String(name || "").toLowerCase())
    if (i >= 0) tab = i
    open()
  }

  onPopupOpenChanged: {
    if (!popupOpen) return
    now = Date.now() / 1000
    selected = -1
    if (!stats || now - (stats.now || 0) > 60) runScan()
    runUsage(false)
  }
  onTabChanged: {
    selected = -1
    if (tab === 4 && !inventory) inventoryProc.running = true
    if (tab === 3) Qt.callLater(function() { if (searchField) searchField.forceActiveFocus() })
    else if (keyCatcher) keyCatcher.forceActiveFocus()
  }
  onQueryChanged: selected = -1

  // ---------------------------------------------------------------- helper processes

  Process {
    id: sessionsProc
    command: [root.helper, "sessions"]
    stdout: StdioCollector { onStreamFinished: root.takeSessions(text) }
  }
  Process {
    id: usageProc
    property bool force: false
    command: force ? [root.helper, "usage", "--force"] : [root.helper, "usage"]
    stdout: StdioCollector { onStreamFinished: root.takeUsage(text) }
  }
  Process {
    id: scanProc
    command: [root.helper, "scan"]
    stdout: StdioCollector { onStreamFinished: { try { var d = JSON.parse(text); if (d.ok) root.stats = d } catch (e) {} } }
  }
  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector { onStreamFinished: { try { root.status = JSON.parse(text) } catch (e) {} } }
  }
  Process {
    id: inventoryProc
    command: [root.helper, "inventory"]
    stdout: StdioCollector { onStreamFinished: { try { var d = JSON.parse(text); if (d.ok) root.inventory = d } catch (e) {} } }
  }

  Process {
    id: jobsProc
    command: [root.helper, "jobs"]
    stdout: StdioCollector { onStreamFinished: root.takeJobs(text) }
  }
  Process {
    id: versionProc
    command: [root.helper, "version"]
    stdout: StdioCollector { onStreamFinished: { try { var d = JSON.parse(text); if (d.local) root.version = d } catch (e) {} } }
  }
  Process {
    id: healthProc
    command: [root.helper, "health"]
    stdout: StdioCollector { onStreamFinished: root.takeHealth(text) }
  }
  Timer { interval: 15000; running: true; repeat: true; triggeredOnStart: true; onTriggered: if (!jobsProc.running) jobsProc.running = true }
  Timer { interval: 6 * 3600 * 1000; running: true; repeat: true; triggeredOnStart: true; onTriggered: if (!versionProc.running) versionProc.running = true }
  Timer { interval: 600000; running: true; repeat: true; triggeredOnStart: true; onTriggered: if (!healthProc.running) healthProc.running = true }

  function runSessions() { if (!sessionsProc.running) sessionsProc.running = true }
  function runUsage(force) {
    if (usageProc.running) return
    usageProc.force = !!force
    usageProc.running = true
  }
  function runScan() { if (!scanProc.running) scanProc.running = true }
  function refreshAll() {
    runSessions(); runUsage(true); runScan()
    if (statusCheck) statusProc.running = true
    if (tab === 4) inventoryProc.running = true
    if (!jobsProc.running) jobsProc.running = true
    if (!healthProc.running) healthProc.running = true
  }

  Timer { interval: root.pollMs; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.runSessions() }
  Timer { interval: root.usageSec * 1000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.runUsage(false) }
  Timer { interval: 300000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.runScan() }
  Timer {
    interval: 300000; running: root.statusCheck; repeat: true; triggeredOnStart: true
    onTriggered: if (!statusProc.running) statusProc.running = true
  }
  Timer { interval: root.popupOpen ? 1000 : 30000; running: true; repeat: true; onTriggered: root.now = Date.now() / 1000 }

  FileView {
    path: root.home + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.themePal = Model.parseTheme(text())
  }

  // ---------------------------------------------------------------- data intake

  function takeSessions(text) {
    var d
    try { d = JSON.parse(text) } catch (e) { return }
    if (!d || !d.ok) return
    var list = Model.sortSessions(d.sessions || [])
    sessions = list
    var focusedPid = 0
    var act = Hyprland.activeToplevel
    if (act && act.lastIpcObject) focusedPid = Number(act.lastIpcObject.pid) || 0
    var r = Model.sessionAlerts(sessionTrack, list, d.now || Date.now() / 1000,
                                { delay: waitingDelay, longBusy: longBusy, focusedPid: focusedPid, contextPct: contextWarnPct })
    sessionTrack = r.track
    for (var i = 0; i < r.alerts.length; i++) {
      var a = r.alerts[i], s = a.session
      if (a.kind === "context") {
        if (!alertContext) continue
        playSound("warning")
        raiseAlert({ kind: "context", pct: a.pct, session: s })
        continue
      }
      if (pulseOn && !popupOpen) pulseAnim.restart()
      playSound(a.kind === "finished" ? "finished" : "needs")
      if (!alertWaiting) continue
      raiseAlert({ kind: a.kind, session: s, ranFor: a.ranFor, quiet: a.quiet })
    }
    // A sticky card goes once its session is no longer waiting on you.
    var waitingPids = {}
    for (var w = 0; w < list.length; w++) if (list[w].status === "waiting" && list[w].approval) waitingPids[list[w].pid] = true
    var keep = cards.filter(function(c) { return !c.sticky || !c.pid || waitingPids[c.pid] })
    if (keep.length !== cards.length) cards = keep
  }

  function takeJobs(text) {
    var d
    try { d = JSON.parse(text) } catch (e) { return }
    if (!d || !d.ok) return
    jobs = d.jobs || []
    var r = Model.jobAlerts(jobState, jobs)
    jobState = r.state
    if (!alertJobs) return
    for (var i = 0; i < r.alerts.length; i++) {
      var a = r.alerts[i], j = a.job
      var good = /^(done|completed|finished)$/.test(a.kind)
      playSound(good ? "finished" : "warning")
      raiseAlert({ kind: good ? "jobdone" : "jobblocked", job: j })
    }
  }

  function takeHealth(text) {
    var d
    try { d = JSON.parse(text) } catch (e) { return }
    if (!d || !d.ok) return
    var before = {}
    ;(health.mcpNeedsAuth || []).forEach(function(m) { before[m.key] = true })
    var primed = health.tokenExpiresAt > 0
    health = d
    // New MCP sign-in problems (not ones that were there when we started).
    if (primed) (d.mcpNeedsAuth || []).forEach(function(m) {
      if (!before[m.key]) { playSound("warning"); raiseAlert({ kind: "mcp", project: m.name, body: m.name + ": open claude and run /mcp to sign in again." }) }
    })
    // The real sign-in (refresh token) ends soon: once a day.
    var days = d.refreshExpiresAt ? (d.refreshExpiresAt - Date.now() / 1000) / 86400 : 99
    if (days < 3 && Date.now() / 1000 - loginWarnedAt > 86400) {
      loginWarnedAt = Date.now() / 1000
      raiseAlert({ kind: "login", expired: days <= 0,
                   body: (days <= 0 ? "Your sign-in has expired." : "Your sign-in ends in " + Model.duration(days * 86400) + ".")
                         + " Run claude and sign in so usage and sessions keep working." })
    }
  }

  function takeUsage(text) {
    var d
    try { d = JSON.parse(text) } catch (e) { return }
    if (!d) return
    if ((d.windows || []).length === 0 && usage.windows.length > 0) {
      usage = Object.assign({}, usage, { stale: true, error: d.error || "no data" })
      return
    }
    usage = d
    var r = Model.limitAlerts(usagePrimed ? limitState : null, d.windows || [])
    limitState = r.state
    usagePrimed = true
    if (!alertLimits) return
    for (var i = 0; i < r.alerts.length; i++) {
      var a = r.alerts[i], w = a.window
      if (a.kind === "reset") raiseAlert({ kind: "reset", window: w, body: w.label + " is back to " + Math.round(w.pct) + "%." })
      else {
        if (a.threshold >= 90) playSound("warning")
        raiseAlert({ kind: "limit", window: w, threshold: a.threshold, body: "Resets in " + Model.duration(w.resetsAt - Date.now() / 1000) + "." })
      }
    }
  }

  function notify(title, body) { raiseAlert({ kind: "info", title: title, body: body }) }

  // ---------------------------------------------------------------- alerts
  //
  // Every alert becomes an entry in Claude Pulse's own log and, unless you
  // are looking at that terminal, a card in the panel's style (top right).
  property var cards: []
  property var alertLog: []
  property int alertSeq: 0
  property bool alertsReady: false
  property string alertsSaved: ""
  property bool alertsView: false
  readonly property int unreadAlerts: alertLog.filter(function(e) { return !e.read }).length

  function toneColor(tone) {
    return tone === "sage" ? pal.green : tone === "red" ? urgentColor : tone === "amber" ? pal.yellow
         : tone === "coral" ? accent : dim
  }

  function raiseAlert(a) {
    var spec = Model.cardSpec(a)
    var s = a.session || null, j = a.job || null
    var call = s && s.approval ? s.approval : null
    var body = a.body
    if (!body && s) {
      body = call && call.detail ? (call.tool ? call.tool.replace(/^mcp__/, "") + ": " : "") + call.detail
           : (s.title || s.prompt || "")
      if (a.kind === "context") body = "Time to /compact or start fresh. " + body
    }
    if (!body && j) body = j.name + (j.needs || j.detail ? ": " + (j.needs || j.detail) : "")
    alertSeq += 1
    var entry = {
      id: Date.now() + "-" + alertSeq, kind: String(a.kind || "info"), headline: spec.headline, title: a.title || "",
      body: String(body || ""), project: s ? s.project : j ? j.project : (a.project || ""), cwd: s ? s.cwd : j ? j.cwd : "",
      sessionId: s ? s.sessionId : j ? j.sessionId : "", pid: s ? s.pid : 0, ts: Date.now() / 1000, read: false,
      tone: spec.tone, button: spec.button, sticky: spec.sticky, glyph: spec.glyph,
      model: s ? (s.modelName || "") : "", tokens: s ? (s.tokens || 0) + ((s.sub || {}).tokens || 0) : (j ? j.tokens || 0 : 0),
      cost: s ? (s.cost || 0) + ((s.sub || {}).cost || 0) : 0, job: j ? { sessionId: j.sessionId, cwd: j.cwd } : null
    }
    alertLog = Model.trimLog([entry].concat(alertLog), 50)
    saveAlerts()
    if (a.quiet) return
    // One card per session: a newer event replaces the older card.
    var rest = cards.filter(function(c) { return !(entry.pid && c.pid === entry.pid) })
    cards = [entry].concat(rest).slice(0, 4)
  }

  function dismissCard(id) { cards = cards.filter(function(c) { return c.id !== id }) }

  // The card's (or log row's) main button.
  function actOn(e) {
    if (!e) return
    if (e.pid) {
      for (var i = 0; i < sessions.length; i++) if (sessions[i].pid === e.pid) { focusSession(sessions[i]); dismissCard(e.id); return }
    }
    if (e.job && e.job.sessionId) { resume({ sessionId: e.job.sessionId, cwd: e.job.cwd }); dismissCard(e.id); return }
    if (e.sessionId && e.cwd) { resume({ sessionId: e.sessionId, cwd: e.cwd }); dismissCard(e.id); return }
    openFor(e)
  }
  function openFor(e) {
    alertsView = false
    tab = e.kind === "limit" || e.kind === "reset" ? 1 : e.kind === "mcp" || e.kind === "login" ? 4 : 0
    open()
    dismissCard(e.id)
  }

  function markAlertsRead() {
    if (!unreadAlerts) return
    alertLog = alertLog.map(function(e) { return Object.assign({}, e, { read: true }) })
    saveAlerts()
  }
  function clearAlerts() { alertLog = []; saveAlerts() }
  function saveAlerts() {
    if (!alertsReady) return
    var text = JSON.stringify(alertLog)
    if (text === alertsSaved) return
    alertsSaved = text
    alertsFile.setText(text)
  }
  FileView {
    id: alertsFile
    path: root.pinsReady ? root.home + "/.local/state/claude-pulse/alerts.json" : ""
    atomicWrites: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var raw = String(text() || "[]")
      root.alertsReady = true
      if (raw === root.alertsSaved) return
      try {
        var list = JSON.parse(raw)
        root.alertLog = Array.isArray(list) ? Model.trimLog(list.filter(function(e) { return e && e.id && e.ts }), 50) : []
      } catch (e) { root.alertLog = [] }
      root.alertsSaved = raw
    }
    onLoadFailed: root.alertsReady = true
  }

  // Sounds: a freedesktop sound name, a full path, or "none".
  function soundFile(name, kind) {
    var n = String(name || "").trim()
    if (n === "" || n === "none" || n === "off") return ""
    if (n === "claude") return Qt.resolvedUrl("assets/sounds/" + kind + ".wav").toString().replace("file://", "")
    var set = /^claude-(marimba|glass)$/.exec(n)
    if (set) return Qt.resolvedUrl("assets/sounds/" + set[1] + "-" + kind + ".wav").toString().replace("file://", "")
    if (n.charAt(0) === "/") return n
    if (!/^[A-Za-z0-9._-]+$/.test(n)) return ""
    return "/usr/share/sounds/freedesktop/stereo/" + (/\.(oga|ogg|wav)$/.test(n) ? n : n + ".oga")
  }
  function playSound(kind) {
    if (!soundsOn) return
    var k = kind === "finished" ? "finished" : kind === "warning" ? "warning" : "needs"
    var file = soundFile(k === "finished" ? soundFinished : k === "warning" ? soundWarning : soundNeedsYou, k)
    if (!file) return
    Quickshell.execDetached(["pw-play", "--volume", String(soundVolume / 100), file])
  }

  // ---- sound picker (Setup → Sounds)
  readonly property var ownSounds: [["claude", "Claude bell"], ["claude-marimba", "Claude marimba"], ["claude-glass", "Claude glass"]]
  readonly property var systemSounds: ["complete", "bell", "message", "message-new-instant", "dialog-information", "dialog-warning",
    "window-attention", "window-question", "service-login", "device-added", "power-plug", "trash-empty", "camera-shutter",
    "network-connectivity-established", "alarm-clock-elapsed"]
  property string soundPicker: ""        // which event's list is open
  function soundLabel(v) {
    for (var i = 0; i < ownSounds.length; i++) if (ownSounds[i][0] === v) return ownSounds[i][1]
    if (v === "none" || v === "") return "None"
    return String(v).replace(/^.*\//, "").replace(/\.(oga|ogg|wav)$/, "").replace(/-/g, " ")
  }
  // Preview always plays, even with sounds off.
  function previewSound(value, kind) {
    var file = soundFile(value, kind)
    if (file) Quickshell.execDetached(["pw-play", "--volume", String(Math.max(soundVolume, 30) / 100), file])
  }
  function setSetting(key, value) {
    Quickshell.execDetached(["omarchy", "bar", "set", "io.github.iammhador.claude-pulse", key, String(value)])
  }

  // ---------------------------------------------------------------- actions

  function windows() {
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    var out = []
    for (var i = 0; i < list.length; i++) {
      var ipc = list[i].lastIpcObject
      if (ipc && ipc.pid) out.push({ pid: Number(ipc.pid), address: String(ipc.address || "") })
    }
    return out
  }

  function focusSession(s) {
    if (!s) return false
    var address = Model.windowFor(s, windows())
    if (!/^0x[0-9a-f]+$/i.test(address)) {
      raiseAlert({ kind: "info", title: "No window found", project: s.project, body: "Couldn't find the terminal for " + s.project + " (pid " + s.pid + ")." })
      return false
    }
    Hyprland.dispatch('hl.dsp.focus({window = hl.get_window("address:' + address + '")})')
    close()
    return true
  }

  function focusWaiting() {
    for (var i = 0; i < sessions.length; i++) if (sessions[i].status === "waiting") return focusSession(sessions[i])
    return false
  }

  // Round-robin through the sessions waiting for you.
  function cycleWaiting() {
    var s = Model.nextWaiting(sessions, lastCycledPid)
    if (!s) return false
    lastCycledPid = s.pid
    return focusSession(s)
  }

  function openEditor(cwd) {
    if (String(cwd || "").charAt(0) !== "/") return
    var cmd = editor === "code" ? ["code", cwd]
            : editor === "zed" ? ["zed", cwd]
            : editor === "nvim" ? ["xdg-terminal-exec", "--dir=" + cwd, "nvim", "."]
            : ["omarchy-launch-editor", cwd]
    Quickshell.execDetached(cmd)
    close()
  }

  // ---- pins: ~/.local/state/claude-pulse/pins.json
  function isPinned(cwd) { return pins.indexOf(cwd) >= 0 }
  function togglePin(cwd) {
    if (String(cwd || "").charAt(0) !== "/") return
    var next = pins.slice()
    var at = next.indexOf(cwd)
    if (at >= 0) next.splice(at, 1); else next.push(cwd)
    pins = next
    savePins()
  }
  function savePins() {
    if (!pinsReady) return
    var text = JSON.stringify(pins)
    if (text === pinsSaved) return
    pinsSaved = text
    pinsFile.setText(text)
  }
  Process {
    running: true
    command: ["bash", "-c", "umask 077; mkdir -p -- \"$1\" && { [ -e \"$1/pins.json\" ] || printf '[]' > \"$1/pins.json\"; [ -e \"$1/alerts.json\" ] || printf '[]' > \"$1/alerts.json\"; }",
              "--", root.home + "/.local/state/claude-pulse"]
    onExited: function(code) { root.pinsReady = code === 0 }
  }
  FileView {
    id: pinsFile
    path: root.pinsReady ? root.home + "/.local/state/claude-pulse/pins.json" : ""
    atomicWrites: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var raw = String(text() || "[]")
      if (raw === root.pinsSaved) return
      try {
        var list = JSON.parse(raw)
        root.pins = Array.isArray(list) ? list.filter(function(x) { return typeof x === "string" && x.charAt(0) === "/" }).slice(0, 30) : []
      } catch (e) { root.pins = [] }
      root.pinsSaved = raw
    }
  }

  // ---- launcher
  function openLauncher(cwd) {
    launchCwd = cwd || (tab === 0 && selected >= 0 && sessions[selected] ? sessions[selected].cwd : "")
                || (pins.length ? pins[0] : "") || root.home
    launcherOpen = true
    open()
    Qt.callLater(function() { if (launchField) { launchField.text = ""; launchField.forceActiveFocus() } })
  }
  function closeLauncher() {
    launcherOpen = false
    if (keyCatcher) keyCatcher.forceActiveFocus()
  }
  function cycleLaunchFolder(dir) {
    var list = [root.home].concat(folders.map(function(f) { return f.cwd }).filter(function(c) { return c !== root.home }))
    var at = Math.max(0, list.indexOf(launchCwd))
    launchCwd = list[(at + dir + list.length) % list.length]
  }
  function launch(prompt) {
    var cwd = launchCwd || root.home
    var args = ["xdg-terminal-exec", "--dir=" + cwd, "claude"]
    var q = String(prompt || "").trim().replace(/^-+\s*/, "")
    if (q !== "") args.push(q)
    Quickshell.execDetached(args)
    launcherOpen = false
    close()
  }
  property var launchField: null

  // Arguments go straight to the program, never through a shell.
  function resume(row) {
    if (!row || !/^[0-9a-f-]{8,64}$/i.test(String(row.sessionId))) return
    Quickshell.execDetached(["xdg-terminal-exec", "--dir=" + (row.cwd || root.home), "claude", "--resume", row.sessionId])
    close()
  }
  function newSession(cwd) {
    Quickshell.execDetached(["xdg-terminal-exec", "--dir=" + (cwd || root.home), "claude"])
    close()
  }
  function openUrl(url) {
    if (!/^https:\/\//.test(String(url))) return
    Quickshell.execDetached(["xdg-open", url])
    close()
  }
  function openFolder(path) {
    if (String(path || "").charAt(0) !== "/") return
    Quickshell.execDetached(["xdg-open", path])
    close()
  }
  property string copiedId: ""
  function copyText(text) {
    Quickshell.execDetached(["wl-copy", "--", String(text)])
    copiedId = String(text)
    copiedTimer.restart()
  }
  Timer { id: copiedTimer; interval: 1500; onTriggered: root.copiedId = "" }

  // ---------------------------------------------------------------- keyboard

  function listLength() { return tab === 0 ? sessions.length : tab === 3 ? historyRows.length : 0 }
  function select(i) {
    var n = listLength()
    selected = n === 0 ? -1 : Math.max(-1, Math.min(n - 1, i))
  }
  function activate() {
    var i = selected >= 0 ? selected : 0
    if (tab === 0 && sessions.length) focusSession(sessions[i])
    else if (tab === 3 && historyRows.length) resume(historyRows[i])
  }

  function handleKey(event, inField) {
    var k = event.key
    if (k === Qt.Key_Escape) {
      if (inField && query !== "") { query = ""; if (searchField) searchField.text = "" }
      else if (selected >= 0) selected = -1
      else close()
      return true
    }
    if (k === Qt.Key_Down) { select(selected + 1); return true }
    if (k === Qt.Key_Up) { select(selected - 1); return true }
    if (k === Qt.Key_Return || k === Qt.Key_Enter) { activate(); return true }
    if (k === Qt.Key_Tab) { tab = (tab + 1) % 5; return true }
    if (k === Qt.Key_Backtab) { tab = (tab + 4) % 5; return true }
    if (inField) return false
    if (k >= Qt.Key_1 && k <= Qt.Key_5) { tab = k - Qt.Key_1; return true }
    if (k === Qt.Key_R) { refreshAll(); return true }
    if (k === Qt.Key_N) { openLauncher(""); return true }
    if (k === Qt.Key_Slash) { tab = 3; return true }
    return false
  }

  // ---------------------------------------------------------------- ipc

  IpcHandler {
    target: "claude-pulse"
    function toggle(): void { root.toggle() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function openTab(name: string): void { root.openTab(name) }
    function refresh(): void { root.refreshAll() }
    function focusWaiting(): bool { return root.focusWaiting() }
    function isOpen(): bool { return root.popupOpen }
    function waitingCount(): int { return root.waiting }
    function pulse(): void { pulseAnim.restart() }
    function launch(): void { root.openLauncher("") }
    function cycleWaiting(): bool { return root.cycleWaiting() }
    function dismissCards(): void { root.cards = [] }
    // Open Setup with a sound list expanded: finished, needs or warning.
    function sounds(kind: string): void {
      root.alertsView = false
      root.tab = 4
      root.soundPicker = kind === "needs" || kind === "warning" ? kind : "finished"
      root.open()
    }
    function clearAlerts(): void { root.clearAlerts() }
    function alerts(): void { root.alertsView = true; root.open(); root.markAlertsRead() }
    function testAlert(kind: string): void {
      var s = root.sessions.length ? root.sessions[0] : { pid: 0, project: "demo", title: "Demo session", modelName: "Opus 5.5", tokens: 1200000, cost: 2.4 }
      var k = String(kind || "finished")
      root.playSound(k === "finished" || k === "jobdone" ? "finished" : k === "context" || k === "limit" ? "warning" : "needs")
      root.raiseAlert({ kind: k, session: Object.assign({}, s, { pid: 0, approval: k === "approval" ? { tool: "Bash", detail: "rm -rf dist" } : null }),
                        ranFor: 252, pct: 83, threshold: 90, window: { label: "Weekly", pct: 91 },
                        job: k.indexOf("job") === 0 ? { name: "demo-job", state: k === "jobdone" ? "done" : "blocked", project: s.project, sessionId: "" } : null })
    }
    function testSound(kind: string): void { root.playSound(kind === "needs" || kind === "warning" ? kind : "finished") }
    function status(): string {
      var lines = []
      if (root.mainWin) lines.push(root.mainWin.label + " " + Math.round(root.mainWin.pct) + "%")
      for (var i = 0; i < root.sessions.length; i++) {
        var s = root.sessions[i]
        lines.push(s.status + "\t" + s.project + "\t" + (s.modelName || "") + "\t" + Model.tokens(s.tokens) + "\t" + Model.cost(s.cost) + "\t" + (s.title || ""))
      }
      return lines.join("\n")
    }
  }

  // ---------------------------------------------------------------- colours

  // Surfaces and text always follow the Omarchy theme; the Claude scheme
  // only brings Claude's accent, gauge, model and project colours.
  readonly property color fg: Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property color faint: Qt.alpha(fg, 0.38)
  readonly property color accent: claudeScheme ? pal.accent : Commons.Color.accent
  readonly property color urgentColor: claudeScheme ? pal.urgent : Commons.Color.urgent
  readonly property color panelBg: Commons.Color.popups.background
  readonly property color onAccent: claudeScheme ? pal.onAccent : Commons.Color.background
  readonly property color subtle: Qt.alpha(fg, 0.06)
  readonly property color line: Qt.alpha(fg, 0.10)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int radius: Math.max(2, Math.round(Style.space(4)))
  function gauge(p) { return Model.gaugeColor(p, pal) }
  function projectColor(name) { return Model.projectColor(name, pal) }
  function modelColor(name) { return Model.modelColor(name, pal) }

  readonly property string claudeGlyph: "\u{ec82}"

  // ================================================================ BAR

  visible: !contextual || sessions.length > 0 || popupOpen
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Rectangle {
    id: ring
    anchors.centerIn: button
    width: Style.space(22); height: width
    radius: width / 2
    color: "transparent"
    border.width: Math.max(1, Style.space(2))
    border.color: root.accent
    opacity: 0
    scale: 0.6
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : face.implicitWidth + Style.space(14)
    fixedHeight: root.vertical ? face.implicitHeight + Style.space(10) : -1
    tooltipText: root.popupOpen ? "" : root.tooltip()
    onPressed: function(b) {
      if (b === Qt.RightButton) { if (!root.focusWaiting()) root.toggle() }
      else if (b === Qt.MiddleButton) root.refreshAll()
      else root.toggle()
    }

    Flow {
      id: face
      anchors.centerIn: parent
      flow: root.vertical ? Flow.TopToBottom : Flow.LeftToRight
      spacing: Style.space(4)
      scale: button.pressScale

      Item {
        width: glyph.implicitWidth
        height: glyph.implicitHeight
        Text {
          id: glyph
          textFormat: Text.PlainText
          text: root.claudeGlyph
          font.family: root.fontFamily
          font.pixelSize: Math.round(Style.font.body * 1.15)
          color: !root.colorBar ? (root.bar ? root.bar.barForeground : root.fg)
                 : root.claudeScheme ? Model.claudeMark(root.mainWin ? root.mainWin.pct : 0, root.pal)
                 : (root.mainWin ? root.gauge(root.mainWin.pct) : (root.bar ? root.bar.barForeground : root.fg))
          transform: Rotation { id: wobble; origin.x: glyph.width / 2; origin.y: glyph.height / 2; angle: 0 }
          SequentialAnimation on opacity {
            running: root.busy > 0 && root.waiting === 0
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { to: 0.45; duration: Style.duration(900); easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: Style.duration(900); easing.type: Easing.InOutSine }
          }
        }
        Rectangle {
          visible: root.otherCritical || root.incident
          width: Style.space(5); height: width; radius: width / 2
          x: parent.width - width / 2; y: -Style.space(1)
          color: root.urgentColor
        }
      }

      Text {
        visible: root.showPercent && root.mainWin !== null && !root.vertical
        textFormat: Text.PlainText
        text: root.mainWin ? Math.round(root.mainWin.pct) + "%" : ""
        color: root.bar ? root.bar.barForeground : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        height: glyph.implicitHeight
        verticalAlignment: Text.AlignVCenter
      }

      Rectangle {
        visible: root.showWaiting && root.waiting > 0
        height: Math.round(Style.font.caption * 1.35)
        width: Math.max(height, waitText.implicitWidth + Style.space(8))
        y: Math.round((glyph.implicitHeight - height) / 2)
        radius: root.radius
        color: flash.running ? root.fg : (root.approvals > 0 ? root.urgentColor : root.accent)
        Text {
          id: waitText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: String(root.waiting)
          color: root.onAccent
          font.family: root.fontFamily
          font.pixelSize: Math.round(Style.font.caption * 0.95)
          font.bold: true
        }
      }
    }
  }

  function tooltip() {
    var parts = []
    if (mainWin) parts.push(mainWin.label + " " + Math.round(mainWin.pct) + "% · resets in " + Model.duration(mainWin.resetsAt - now))
    if (bw.worst && bw.worst.pct >= 90) parts.push(bw.worst.label + " " + Math.round(bw.worst.pct) + "%")
    if (sessions.length) parts.push(sessions.length + (sessions.length === 1 ? " session" : " sessions")
                                     + (waiting ? " · " + waiting + " waiting" : "") + (busy ? " · " + busy + " working" : ""))
    if (incident) parts.push("Claude status: " + status.description)
    if (usage.error) parts.push("Usage: " + usage.error)
    return parts.join("\n")
  }

  Timer { id: flash; interval: Style.duration(1200) > 0 ? 1200 : 0 }
  ParallelAnimation {
    id: pulseAnim
    onStarted: if (flash.interval > 0) flash.restart()
    SequentialAnimation {
      NumberAnimation { target: wobble; property: "angle"; to: -25; duration: Style.duration(110); easing.type: Easing.OutCubic }
      NumberAnimation { target: wobble; property: "angle"; to: 18; duration: Style.duration(140); easing.type: Easing.InOutSine }
      NumberAnimation { target: wobble; property: "angle"; to: -8; duration: Style.duration(130); easing.type: Easing.InOutSine }
      NumberAnimation { target: wobble; property: "angle"; to: 0; duration: Style.duration(130); easing.type: Easing.OutCubic }
    }
    SequentialAnimation {
      PropertyAction { target: ring; property: "scale"; value: 0.6 }
      PropertyAction { target: ring; property: "opacity"; value: 0.9 }
      ParallelAnimation {
        NumberAnimation { target: ring; property: "scale"; to: 1.8; duration: Style.duration(800); easing.type: Easing.OutCubic }
        NumberAnimation { target: ring; property: "opacity"; to: 0; duration: Style.duration(800); easing.type: Easing.OutCubic }
      }
    }
  }

  // ================================================================ ALERT CARDS
  //
  // Our own notification cards: the panel's look, top right under the bar.
  // A ListModel keeps cards that are already on screen stable (no re-entry,
  // no countdown reset) when a new one arrives.

  ListModel { id: cardModel }
  function cardById(id) {
    for (var i = 0; i < cards.length; i++) if (cards[i].id === id) return cards[i]
    return null
  }
  onCardsChanged: {
    var ids = {}
    for (var i = 0; i < cards.length; i++) ids[cards[i].id] = true
    for (var r = cardModel.count - 1; r >= 0; r--) if (!ids[cardModel.get(r).cid]) cardModel.remove(r)
    var have = {}
    for (var m = 0; m < cardModel.count; m++) have[cardModel.get(m).cid] = true
    for (var n = cards.length - 1; n >= 0; n--) if (!have[cards[n].id]) cardModel.insert(0, { cid: cards[n].id })
  }

  PanelWindow {
    id: cardWindow
    visible: cardModel.count > 0
    screen: {
      var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
      var list = Quickshell.screens
      for (var i = 0; i < list.length; i++) if (list[i].name === name) return list[i]
      return list.length ? list[0] : null
    }
    anchors.top: true
    anchors.right: true
    margins.top: Style.space(8)
    margins.right: Style.space(10)
    implicitWidth: Style.space(400)
    implicitHeight: Math.max(1, cardsCol.implicitHeight + Style.space(20))
    color: "transparent"
    WlrLayershell.namespace: "claude-pulse-cards"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // Sit under the bar, without pushing windows away.
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: 0
    // Only the cards take clicks; the rest of the screen stays usable.
    mask: Region { item: cardsCol }

    Column {
      id: cardsCol
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      spacing: Style.space(8)
      Repeater {
        model: cardModel
        AlertCard {
          required property string cid
          e: root.cardById(cid) || ({})
        }
      }
    }
  }

  // ================================================================ PANEL

  property var searchField: null
  property var keyCatcher: null

  KeyboardPanel {
    id: panel
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: root.tab === 3 ? search : keys
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.cappedContentHeight(Style.space(660))

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Component.onCompleted: { root.keyCatcher = keys; root.searchField = search }
      Keys.onPressed: function(event) { if (root.handleKey(event, false)) event.accepted = true }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(12)

        // ---- header -------------------------------------------------------
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          z: 3
          Text {
            textFormat: Text.PlainText
            text: root.claudeGlyph
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.title * 1.15
          }
          Text {
            textFormat: Text.PlainText
            text: "Claude"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Tag { visible: root.usage.plan !== ""; label: root.usage.plan; tint: root.accent }
          // Status: a dot, with the detail on hover.
          Item {
            visible: root.statusCheck
            implicitWidth: Style.space(18); implicitHeight: Style.space(18)
            Rectangle {
              anchors.centerIn: parent
              width: Style.space(7); height: width; radius: width / 2
              color: root.incident ? root.urgentColor : (root.status.indicator === "unknown" ? root.dim : root.pal.green)
              SequentialAnimation on opacity {
                running: root.incident; loops: Animation.Infinite; alwaysRunToEnd: true
                NumberAnimation { to: 0.3; duration: 700 }
                NumberAnimation { to: 1; duration: 700 }
              }
            }
            HoverHandler { id: statusHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.openUrl("https://status.claude.com") }
            Hint {
              shown: statusHover.hovered
              anchors.top: parent.bottom; anchors.left: parent.left
              label: root.status.description || (root.status.indicator === "unknown" ? "Status unknown (offline?)" : "All systems operational")
            }
          }
          Item { Layout.fillWidth: true }
          IconButton {
            glyph: root.unreadAlerts > 0 ? "\u{f116b}" : "\u{f009a}"
            hint: root.alertsView ? "Back to tabs" : "Alerts"
            on: root.alertsView
            badge: root.unreadAlerts
            onClicked: { root.alertsView = !root.alertsView; if (root.alertsView) root.markAlertsRead() }
          }
          IconButton { glyph: "\u{f0415}"; hint: "Ask Claude… (n)"; onClicked: root.launcherOpen ? root.closeLauncher() : root.openLauncher("") }
          IconButton {
            glyph: "\u{f0450}"; hint: "Refresh (r)"
            spinning: scanProc.running || usageProc.running
            onClicked: root.refreshAll()
          }
          IconButton { glyph: "\u{f03cc}"; hint: "Usage on claude.ai"; onClicked: root.openUrl("https://claude.ai/settings/usage") }
        }

        // ---- hero ---------------------------------------------------------
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(14)

          Ring {
            Layout.preferredWidth: Style.space(62)
            Layout.preferredHeight: Style.space(62)
            pct: root.sessionWin ? root.sessionWin.pct : 0
            known: root.sessionWin !== null
            caption: "session"
            onClicked: root.tab = 1
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: 0
            readonly property var sp: root.sessionWin ? Model.pace(root.sessionWin, root.now) : null
            HeroStat {
              Layout.fillWidth: true
              value: root.sessionWin ? Model.duration(root.sessionWin.resetsAt - root.now) : "–"
              caption: parent.sp && parent.sp.state !== "unknown"
                       ? parent.sp.arrow + " " + (parent.sp.state === "on" ? "on pace" : Math.abs(parent.sp.delta) + " pts " + (parent.sp.delta > 0 ? "ahead" : "under"))
                       : "until reset"
              tint: !parent.sp ? root.fg : parent.sp.state === "hot" ? root.urgentColor : parent.sp.state === "ahead" ? root.pal.yellow : root.fg
              onClicked: root.tab = 1
            }
            Divider {}
            HeroStat {
              Layout.fillWidth: true
              value: root.weeklyWin ? Math.round(root.weeklyWin.pct) + "%" : "–"
              tint: root.weeklyWin ? root.gauge(root.weeklyWin.pct) : root.fg
              caption: "weekly"
              onClicked: root.tab = 1
            }
            Divider {}
            HeroStat {
              Layout.fillWidth: true
              value: !root.stats ? "–" : root.showCost ? Model.cost(root.stats.today.cost) : Model.tokens(root.stats.today.tokens)
              caption: root.showCost ? "today" : "tokens today"
              onClicked: root.tab = 2
            }
            Divider {}
            HeroStat {
              Layout.fillWidth: true
              value: root.approvals > 0 ? String(root.approvals) : root.waiting > 0 ? String(root.waiting) : String(root.sessions.length)
              tint: root.approvals > 0 ? root.urgentColor : root.waiting > 0 ? root.accent : root.fg
              caption: root.approvals > 0 ? "need approval" : root.waiting > 0 ? "waiting" : (root.busy > 0 ? root.busy + " working" : "sessions")
              onClicked: root.tab = 0
            }
          }
        }

        // ---- launcher -------------------------------------------------------
        Column {
          Layout.fillWidth: true
          visible: root.launcherOpen
          spacing: Style.space(8)
          TextField {
            id: launchInput
            width: parent.width
            leftPadding: Style.space(32)
            placeholderText: "Ask Claude…  Enter to start in " + Model.shortPath(root.launchCwd, root.home) + "  ·  Tab: folder  ·  Esc"
            foreground: root.fg
            accent: root.accent
            Component.onCompleted: root.launchField = launchInput
            background: Rectangle {
              radius: root.radius
              color: root.subtle
              border.width: 1
              border.color: launchInput.activeFocus ? root.accent : root.line
            }
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) { root.closeLauncher(); event.accepted = true }
              else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.launch(launchInput.text); event.accepted = true }
              else if (event.key === Qt.Key_Tab) { root.cycleLaunchFolder(1); event.accepted = true }
              else if (event.key === Qt.Key_Backtab) { root.cycleLaunchFolder(-1); event.accepted = true }
            }
            Text {
              anchors.left: parent.left; anchors.leftMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText; text: root.claudeGlyph; color: root.accent
              font.family: root.fontFamily; font.pixelSize: Style.font.body
            }
          }
          FolderStrip { width: parent.width; chosen: root.launchCwd; withHome: true; onPicked: function(cwd) { root.launchCwd = cwd; if (root.launchField) root.launchField.forceActiveFocus() } }
        }

        // ---- incident banner ----------------------------------------------
        Rectangle {
          Layout.fillWidth: true
          visible: root.incident
          implicitHeight: banner.implicitHeight + Style.space(14)
          radius: root.radius
          color: Qt.alpha(root.urgentColor, 0.12)
          HoverHandler { cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: root.openUrl(root.status.incidents.length ? root.status.incidents[0].url : "https://status.claude.com") }
          Rectangle { width: Style.space(3); height: parent.height; radius: 1; color: root.urgentColor }
          Column {
            id: banner
            anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12); anchors.rightMargin: Style.space(10)
            spacing: Style.space(2)
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.status.description
              color: root.urgentColor
              font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
              elide: Text.ElideRight
            }
            Repeater {
              model: root.status.incidents || []
              Text {
                required property var modelData
                width: parent.width
                textFormat: Text.PlainText
                text: modelData.name + " · " + modelData.status
                color: root.fg
                font.family: root.fontFamily; font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }
        }

        // ---- tabs -----------------------------------------------------------
        Item {
          Layout.fillWidth: true
          implicitHeight: tabsRow.implicitHeight
          Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.line }
          Row {
            id: tabsRow
            spacing: Style.space(18)
            Tab { glyph: "\u{f040a}"; label: "Live"; count: root.sessions.length; badge: root.waiting; selected: root.tab === 0; onClicked: root.tab = 0 }
            Tab { glyph: "\u{f029a}"; label: "Usage"; selected: root.tab === 1; onClicked: root.tab = 1 }
            Tab { glyph: "\u{f0128}"; label: "Stats"; selected: root.tab === 2; onClicked: root.tab = 2 }
            Tab { glyph: "\u{f02da}"; label: "History"; selected: root.tab === 3; onClicked: root.tab = 3 }
            Tab { glyph: "\u{f0493}"; label: "Setup"; dot: root.healthIssue; selected: root.tab === 4; onClicked: root.tab = 4 }
          }
        }

        // ---- alerts log -----------------------------------------------------
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.alertsView
          spacing: Style.space(10)
          RowLayout {
            Layout.fillWidth: true
            SectionLabel { text: "Alerts · last " + root.alertLog.length }
            Item { Layout.fillWidth: true }
            Tag { visible: root.alertLog.length > 0; label: "Clear"; tint: root.dim; clickable: true; onClicked: root.clearAlerts() }
          }
          Scroller {
            id: alertScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            Column {
              width: alertScroll.width
              spacing: Style.space(2)
              Repeater {
                model: root.alertLog
                AlertRow { required property var modelData; e: modelData; width: parent.width }
              }
              Empty {
                visible: root.alertLog.length === 0
                width: parent.width; height: alertScroll.height
                glyph: "\u{f009a}"
                message: "No alerts yet."
              }
            }
          }
        }

        StackLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: !root.alertsView
          currentIndex: root.tab

          // ================================================== LIVE
          Scroller {
            id: liveScroll
            Column {
              width: liveScroll.width
              spacing: Style.space(2)
              Repeater {
                model: root.sessions
                SessionRow {
                  required property var modelData
                  required property int index
                  s: modelData
                  rowIndex: index
                  width: parent.width
                }
              }
              Empty {
                visible: root.sessions.length === 0
                width: parent.width
                height: root.jobs.length ? Style.space(170) : liveScroll.height
                glyph: root.claudeGlyph
                message: "No Claude Code session is running."
                actionLabel: "Ask Claude…"
                onAction: root.openLauncher("")
              }

              Column {
                width: parent.width
                visible: root.jobs.length > 0
                topPadding: Style.space(12)
                spacing: Style.space(4)
                SectionLabel { text: "Background jobs · last 7 days" }
                Repeater {
                  model: root.jobs
                  JobRow { required property var modelData; j: modelData; width: parent.width }
                }
              }
            }
          }

          // ================================================== USAGE
          Scroller {
            id: usageScroll
            Column {
              width: usageScroll.width
              spacing: Style.space(18)
              topPadding: Style.space(4)

              Repeater {
                model: root.usage.windows || []
                LimitMeter { required property var modelData; w: modelData; width: parent.width }
              }

              Empty {
                visible: (root.usage.windows || []).length === 0
                width: parent.width; height: Style.space(200)
                glyph: "\u{f029a}"
                message: root.usage.error ? "Usage unavailable: " + root.usage.error : "Loading usage…"
              }

              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: (root.usage.breakdown || []).some(function(r) { return r.pct > 0 })
                SectionLabel { text: "This week by surface" }
                // One stacked bar, then a legend.
                Row {
                  width: parent.width
                  height: Style.space(6)
                  spacing: Style.space(2)
                  Repeater {
                    model: (root.usage.breakdown || []).filter(function(r) { return r.pct > 0 })
                    Rectangle {
                      required property var modelData
                      required property int index
                      height: parent.height
                      width: Math.max(height, (parent.width - parent.spacing * 3) * modelData.pct / 100)
                      radius: root.radius / 2
                      color: [root.accent, root.pal.magenta, root.pal.cyan, root.pal.yellow][index % 4]
                    }
                  }
                }
                Flow {
                  width: parent.width
                  spacing: Style.space(14)
                  Repeater {
                    model: (root.usage.breakdown || []).filter(function(r) { return r.pct > 0 })
                    Row {
                      required property var modelData
                      required property int index
                      spacing: Style.space(5)
                      Rectangle { anchors.verticalCenter: parent.verticalCenter; width: Style.space(7); height: width; radius: 2; color: [root.accent, root.pal.magenta, root.pal.cyan, root.pal.yellow][index % 4] }
                      Text { textFormat: Text.PlainText; text: modelData.label + " " + modelData.pct + "%"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    }
                  }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(6)
                visible: root.usage.extra !== null && root.usage.extra !== undefined
                SectionLabel { text: "Extra usage" }
                BarLine {
                  width: parent.width
                  readonly property var ex: root.usage.extra || ({})
                  label: "Spent " + Model.cost(ex.used) + (ex.limit ? " of " + Model.cost(ex.limit) : "")
                  value: ex.balance !== null && ex.balance !== undefined ? Model.cost(ex.balance) + " left" : ""
                  ratio: ex.limit ? ex.used / ex.limit : 0
                  tint: root.gauge(ex.limit ? 100 * ex.used / ex.limit : 0)
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: (root.usage.updatedAt ? "Updated " + Model.ago(root.usage.updatedAt, root.now) : "Not updated yet")
                  + (root.usage.stale && root.usage.error ? " · " + root.usage.error : "")
                  + (root.usage.retryAt > root.now ? " · next try in " + Model.duration(root.usage.retryAt - root.now) : "")
                  + "  ·  the white mark is an even burn rate"
                color: root.usage.stale ? root.pal.orange : root.faint
                font.family: root.fontFamily; font.pixelSize: Style.font.caption
              }
            }
          }

          // ================================================== STATS
          Scroller {
            id: statsScroll
            Column {
              width: statsScroll.width
              spacing: Style.space(18)
              topPadding: Style.space(4)
              visible: root.stats !== null

              FlatStats {
                width: parent.width
                items: root.stats ? [
                  [root.showCost ? Model.cost(root.stats.today.cost) : Model.tokens(root.stats.today.tokens), "Today", Model.tokens(root.stats.today.tokens) + " tok"],
                  [root.showCost ? Model.cost(root.stats.week.cost) : Model.tokens(root.stats.week.tokens), "7 days", Model.tokens(root.stats.week.tokens) + " tok"],
                  [root.showCost ? Model.cost(root.stats.month.cost) : Model.tokens(root.stats.month.tokens), "30 days", Model.tokens(root.stats.month.tokens) + " tok"]] : []
              }

              // 7-day chart.
              Item {
                width: parent.width
                height: Style.space(104)
                Row {
                  anchors.fill: parent
                  spacing: Style.space(8)
                  Repeater {
                    model: root.stats ? Model.chartBars(root.stats.chart) : []
                    Item {
                      required property var modelData
                      required property int index
                      readonly property bool today: index === 6
                      width: (parent.width - 6 * parent.spacing) / 7
                      height: parent.height
                      HoverHandler { id: barHover }
                      Text {
                        id: dayLabel
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        textFormat: Text.PlainText
                        text: parent.today ? "Today" : modelData.label
                        color: parent.today ? root.fg : root.dim
                        font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: parent.today
                      }
                      Rectangle {
                        id: bar7
                        anchors.bottom: dayLabel.top
                        anchors.bottomMargin: Style.space(5)
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width * 0.7
                        height: Math.max(2, (parent.height - dayLabel.height - Style.space(24)) * modelData.ratio)
                        radius: root.radius / 2
                        color: parent.today || barHover.hovered ? root.accent : Qt.alpha(root.accent, 0.38)
                        Behavior on height { NumberAnimation { duration: Style.duration(400); easing.type: Easing.OutCubic } }
                      }
                      Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: bar7.top
                        anchors.bottomMargin: Style.space(3)
                        visible: modelData.cost > 0 || modelData.tokens > 0
                        textFormat: Text.PlainText
                        text: root.showCost ? Model.cost(modelData.cost).replace(".00", "") : Model.tokens(modelData.tokens)
                        color: parent.today || barHover.hovered ? root.fg : root.faint
                        font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.9)
                      }
                    }
                  }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(12)
                SectionLabel { text: "Projects · last 7 days" }
                Repeater {
                  model: root.stats ? root.stats.projects : []
                  ProjectRow { required property var modelData; p: modelData; width: parent.width }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(10)
                SectionLabel { text: "Models · last 7 days" }
                Repeater {
                  model: root.stats ? root.stats.models : []
                  Column {
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(4)
                    RowLayout {
                      width: parent.width
                      spacing: Style.space(8)
                      ModelTag { model: modelData.model }
                      Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: modelData.messages + " replies"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; text: (root.showCost ? Model.cost(modelData.cost) + "  ·  " : "") + Model.tokens(modelData.tokens); color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                    }
                    Thin { width: parent.width; ratio: root.stats.week.tokens ? modelData.tokens / root.stats.week.tokens : 0; tint: root.modelColor(modelData.model) }
                  }
                }
              }

              Text {
                width: parent.width
                visible: root.showCost
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: "Costs are API-equivalent estimates from local transcripts, cache included. Your plan bills a flat fee."
                color: root.faint
                font.family: root.fontFamily; font.pixelSize: Style.font.caption
              }
            }
            Empty { visible: root.stats === null; width: statsScroll.width; height: statsScroll.height; glyph: "\u{f0128}"; message: "Reading transcripts…" }
          }

          // ================================================== HISTORY
          ColumnLayout {
            spacing: Style.space(10)

            TextField {
              id: search
              Layout.fillWidth: true
              leftPadding: Style.space(32)
              placeholderText: "Search project, title, prompt, branch"
              foreground: root.fg
              accent: root.accent
              background: Rectangle {
                radius: root.radius
                color: root.subtle
                border.width: search.activeFocus ? 1 : 0
                border.color: Qt.alpha(root.accent, 0.6)
              }
              onTextEdited: root.query = text
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) { if (root.handleKey(event, true)) event.accepted = true }
              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(11)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "\u{f0349}"
                color: root.dim
                font.family: root.fontFamily; font.pixelSize: Style.font.body
              }
            }

            // Start a new session in a recent folder: one scrolling strip.
            Column {
              Layout.fillWidth: true
              spacing: Style.space(6)
              visible: root.query === "" && root.folders.length > 0
              SectionLabel { text: "New session in  ·  right-click to pin" }
              FolderStrip { width: parent.width; onPicked: function(cwd) { root.openLauncher(cwd) } }
            }

            Scroller {
              id: historyScroll
              Layout.fillWidth: true
              Layout.fillHeight: true
              Column {
                width: historyScroll.width
                spacing: Style.space(2)
                Repeater {
                  model: root.historyRows
                  HistoryRow { required property var modelData; required property int index; r: modelData; rowIndex: index; width: parent.width }
                }
                Empty {
                  visible: root.historyRows.length === 0
                  width: parent.width; height: Style.space(200)
                  glyph: "\u{f02da}"
                  message: root.query ? "Nothing matches “" + root.query + "”." : "No past sessions in the last 30 days."
                }
              }
            }
          }

          // ================================================== SETUP
          Scroller {
            id: setupScroll
            Column {
              width: setupScroll.width
              spacing: Style.space(18)
              topPadding: Style.space(4)
              visible: root.inventory !== null

              // ---- health
              Column {
                width: parent.width
                spacing: Style.space(8)
                SectionLabel { text: "Health" }
                HealthLine {
                  glyph: "\u{f0a1e}"
                  level: root.version.update ? "warn" : "ok"
                  label: "Claude Code " + (root.version.local || "?")
                  detail: root.version.update ? "Update " + root.version.latest + " available" : (root.version.latest ? "up to date" : "")
                  actionLabel: root.version.update ? "Update" : ""
                  onAction: { Quickshell.execDetached(["xdg-terminal-exec", "claude", "update"]); root.close() }
                }
                HealthLine {
                  glyph: "\u{f0306}"
                  level: !root.health.signedIn || root.loginDaysLeft <= 0 ? "bad" : root.loginDaysLeft < 3 ? "warn" : "ok"
                  label: !root.health.signedIn ? "Not signed in" : "Signed in" + (root.health.plan ? " · " + root.health.plan.charAt(0).toUpperCase() + root.health.plan.slice(1) : "")
                  detail: !root.health.signedIn ? "run claude to sign in"
                          : root.loginDaysLeft <= 0 ? "sign-in expired: run claude"
                          : "token refreshes itself · sign-in valid " + Model.duration(root.loginDaysLeft * 86400) + " more"
                }
                Repeater {
                  model: root.health.mcpNeedsAuth || []
                  HealthLine {
                    required property var modelData
                    glyph: "\u{f048b}"
                    level: "bad"
                    label: "MCP " + modelData.name + " needs sign-in"
                    detail: "open claude and run /mcp" + (modelData.source && modelData.source !== "user" ? " · from " + modelData.source : "")
                  }
                }
              }

              // ---- sounds
              Column {
                width: parent.width
                spacing: Style.space(8)
                RowLayout {
                  width: parent.width
                  spacing: Style.space(6)
                  SectionLabel { text: "Sounds" }
                  Item { Layout.fillWidth: true }
                  Tag { label: root.soundsOn ? "On" : "Off"; tint: root.soundsOn ? root.pal.green : root.dim; clickable: true; onClicked: root.setSetting("sounds", root.soundsOn ? "false" : "true") }
                  Tag { label: "−"; tint: root.dim; clickable: true; onClicked: root.setSetting("soundVolume", Math.max(0, root.soundVolume - 10)) }
                  Text { textFormat: Text.PlainText; text: root.soundVolume + "%"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  Tag { label: "+"; tint: root.dim; clickable: true; onClicked: root.setSetting("soundVolume", Math.min(100, root.soundVolume + 10)) }
                }
                SoundRow { kind: "finished"; title: "Claude finished"; key: "soundFinished"; value: root.soundFinished; width: parent.width }
                SoundRow { kind: "needs"; title: "Needs you"; key: "soundNeedsYou"; value: root.soundNeedsYou; width: parent.width }
                SoundRow { kind: "warning"; title: "Warning"; key: "soundWarning"; value: root.soundWarning; width: parent.width }
              }

              FlatStats {
                width: parent.width
                items: root.inventory ? [
                  [String(root.inventory.plugins.length), "Plugins", root.inventory.plugins.filter(function(p) { return p.enabled }).length + " enabled"],
                  [String(root.inventory.skills.length + root.inventory.plugins.reduce(function(n, p) { return n + p.skills.length }, 0)), "Skills", root.inventory.skills.length + " personal"],
                  [String(root.inventory.mcp.length), "MCP servers", root.inventory.mcp.filter(function(m) { return m.scope.indexOf("plugin:") === 0 }).length + " from plugins"]] : []
              }

              Column {
                width: parent.width
                spacing: Style.space(10)
                SectionLabel { text: "Plugins" }
                Repeater {
                  model: root.inventory ? root.inventory.plugins : []
                  RowLayout {
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(10)
                    ProjectTile { Layout.alignment: Qt.AlignTop; name: modelData.name; size: Style.space(26); dimmed: !modelData.enabled }
                    Column {
                      Layout.fillWidth: true
                      spacing: Style.space(2)
                      RowLayout {
                        width: parent.width
                        spacing: Style.space(6)
                        Text { textFormat: Text.PlainText; text: modelData.name; color: modelData.enabled ? root.fg : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
                        Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: modelData.enabled ? modelData.market : modelData.market + " · disabled"; color: root.faint; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                        Text { textFormat: Text.PlainText; text: modelData.version; color: root.faint; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                      }
                      Text {
                        width: parent.width
                        visible: text !== ""
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        text: [].concat(modelData.skills, modelData.commands.map(function(c) { return "/" + c }),
                                        modelData.agents.map(function(a) { return "agent:" + a }),
                                        modelData.mcp.map(function(m) { return "mcp:" + m })).join("  ·  ")
                        color: root.dim
                        font.family: root.fontFamily; font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(8)
                SectionLabel { text: "Personal skills" }
                Repeater {
                  model: root.inventory ? root.inventory.skills : []
                  Column {
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(1)
                    Text { textFormat: Text.PlainText; text: modelData.name; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
                    Text { width: parent.width; textFormat: Text.PlainText; text: modelData.description; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                  }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(6)
                SectionLabel { text: "MCP servers" }
                Repeater {
                  model: root.inventory ? root.inventory.mcp : []
                  RowLayout {
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(8)
                    Text { textFormat: Text.PlainText; text: "\u{f048b}"; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
                    Text { textFormat: Text.PlainText; text: modelData.name; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
                    Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: modelData.scope + (modelData.type ? " · " + modelData.type : ""); color: root.faint; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  }
                }
                Text {
                  visible: root.inventory !== null && root.inventory.mcp.length === 0
                  textFormat: Text.PlainText; text: "None configured."
                  color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                }
              }
            }
            Empty { visible: root.inventory === null; width: setupScroll.width; height: setupScroll.height; glyph: "\u{f0493}"; message: "Reading your setup…" }
          }
        }

        // ---- footer hint ----------------------------------------------------
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: "1–5 tabs  ·  ↑↓ Enter  ·  n new  ·  r refresh  ·  Esc close"
          color: root.faint
          font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.92)
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  // ================================================================ PARTS

  component Scroller: Flickable {
    clip: true
    contentHeight: contentItem.childrenRect.height
    boundsBehavior: Flickable.StopAtBounds
  }

  component SectionLabel: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Math.round(Style.font.caption * 0.92)
    font.bold: true
    font.letterSpacing: 1.2
    font.capitalization: Font.AllUppercase
  }

  component Divider: Rectangle {
    Layout.preferredWidth: 1
    Layout.preferredHeight: Style.space(30)
    Layout.alignment: Qt.AlignVCenter
    color: root.line
  }

  component Hint: Rectangle {
    id: hint
    property string label: ""
    property bool shown: false
    visible: shown && label !== ""
    z: 20
    width: hintText.implicitWidth + Style.space(12)
    height: hintText.implicitHeight + Style.space(6)
    radius: root.radius
    color: root.panelBg
    border.width: 1; border.color: root.line
    Text { id: hintText; anchors.centerIn: parent; textFormat: Text.PlainText; text: hint.label; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
  }

  component Empty: Item {
    id: em
    property string glyph: ""
    property string message: ""
    property string actionLabel: ""
    signal action()
    Column {
      anchors.centerIn: parent
      spacing: Style.space(10)
      Text { anchors.horizontalCenter: parent.horizontalCenter; textFormat: Text.PlainText; text: em.glyph; color: Qt.alpha(root.fg, 0.16); font.family: root.fontFamily; font.pixelSize: Style.font.displayLarge * 1.2 }
      Text { anchors.horizontalCenter: parent.horizontalCenter; textFormat: Text.PlainText; text: em.message; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.body }
      Tag { anchors.horizontalCenter: parent.horizontalCenter; visible: em.actionLabel !== ""; label: em.actionLabel; tint: root.accent; clickable: true; onClicked: em.action() }
    }
  }

  // Flat label: tinted text on a faint tint, 4 px corners.
  component Tag: Rectangle {
    id: tg
    property string label: ""
    property color tint: root.accent
    property bool clickable: false
    signal clicked()
    implicitWidth: tgText.implicitWidth + Style.space(12)
    implicitHeight: tgText.implicitHeight + Style.space(4)
    radius: root.radius
    color: tgHover.hovered && clickable ? Qt.alpha(tint, 0.24) : Qt.alpha(tint, 0.14)
    HoverHandler { id: tgHover; cursorShape: tg.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor }
    TapHandler { enabled: tg.clickable; onTapped: tg.clicked() }
    Text {
      id: tgText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: tg.label
      color: tg.tint
      font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.95); font.bold: true
    }
  }

  component ModelTag: Tag {
    property string model: ""
    label: model
    tint: root.modelColor(model)
    visible: model !== ""
  }

  // A project's identity: its letter on a faint square of its colour.
  component ProjectTile: Rectangle {
    id: pt
    property string name: ""
    property real size: Style.space(34)
    property bool dimmed: false
    readonly property color tone: dimmed ? root.dim : root.projectColor(name)
    implicitWidth: size
    implicitHeight: size
    radius: root.radius
    color: Qt.alpha(tone, 0.16)
    border.width: 1
    border.color: Qt.alpha(tone, 0.28)
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: Model.projectLetter(pt.name)
      color: pt.tone
      font.family: root.fontFamily
      font.pixelSize: Math.round(pt.size * 0.48)
      font.bold: true
    }
  }

  component IconButton: Rectangle {
    id: ib
    property string glyph: ""
    property string hint: ""
    property bool spinning: false
    property bool on: false
    property int badge: 0
    signal clicked()
    implicitWidth: Style.space(30)
    implicitHeight: Style.space(30)
    radius: root.radius
    color: ib.on ? Qt.alpha(root.accent, 0.14) : ibHover.hovered ? root.subtle : "transparent"
    HoverHandler { id: ibHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: ib.clicked() }
    Rectangle {
      visible: ib.badge > 0
      z: 2
      x: parent.width - width + Style.space(2); y: -Style.space(2)
      height: Math.round(Style.font.caption * 1.2)
      width: Math.max(height, ibBadge.implicitWidth + Style.space(6))
      radius: root.radius
      color: root.accent
      Text { id: ibBadge; anchors.centerIn: parent; textFormat: Text.PlainText; text: ib.badge > 99 ? "99+" : String(ib.badge); color: root.onAccent; font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.85); font.bold: true }
    }
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: ib.glyph
      color: ib.on ? root.accent : ibHover.hovered ? root.fg : root.dim
      font.family: root.fontFamily; font.pixelSize: Style.font.title
      RotationAnimation on rotation { running: ib.spinning; from: 0; to: 360; duration: 900; loops: Animation.Infinite }
    }
    Hint { shown: ibHover.hovered; label: ib.hint; anchors.top: parent.bottom; anchors.topMargin: Style.space(4); anchors.right: parent.right }
  }

  // Small action on a row; its MouseArea sits above the row's own tap.
  component RowAction: Rectangle {
    id: ra
    property string glyph: ""
    property string hint: ""
    property bool done: false
    signal clicked()
    width: Style.space(24)
    height: Style.space(22)
    radius: root.radius
    color: raHover.hovered ? Qt.alpha(root.fg, 0.1) : "transparent"
    HoverHandler { id: raHover; cursorShape: Qt.PointingHandCursor }
    MouseArea { anchors.fill: parent; onClicked: ra.clicked() }
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: ra.done ? "\u{f012c}" : ra.glyph
      color: ra.done ? root.pal.green : (raHover.hovered ? root.fg : root.dim)
      font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
    }
    Hint { shown: raHover.hovered; label: ra.done ? "Copied" : ra.hint; anchors.bottom: parent.top; anchors.bottomMargin: Style.space(3); anchors.right: parent.right }
  }

  component Tab: Item {
    id: t
    property string glyph: ""
    property string label: ""
    property int count: -1
    property int badge: 0
    property bool dot: false
    property bool selected: false
    signal clicked()
    implicitWidth: tRow.implicitWidth + (dot ? Style.space(6) : 0)
    Rectangle { visible: t.dot; anchors.right: parent.right; y: Style.space(1); width: Style.space(5); height: width; radius: width / 2; color: root.accent }
    implicitHeight: tRow.implicitHeight + Style.space(10)
    HoverHandler { id: tHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: { root.alertsView = false; t.clicked() } }
    Row {
      id: tRow
      spacing: Style.space(6)
      Text { textFormat: Text.PlainText; text: t.glyph; color: t.selected ? root.accent : (tHover.hovered ? root.fg : root.dim); font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
      Text { textFormat: Text.PlainText; text: t.label; color: t.selected || tHover.hovered ? root.fg : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: t.selected }
      Text {
        visible: t.count >= 0
        textFormat: Text.PlainText
        text: t.badge > 0 ? t.badge + "/" + t.count : String(t.count)
        color: t.badge > 0 || t.selected ? root.accent : root.faint
        font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: t.badge > 0
        y: Math.round((Style.font.bodySmall - Style.font.caption) * 0.8)
      }
    }
    Rectangle {
      anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.right: parent.right
      height: 2; radius: 1
      color: root.accent
      opacity: t.selected && !root.alertsView ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: Style.duration(150) } }
    }
  }

  // Big value over a small caption; the whole thing is a shortcut.
  component HeroStat: Item {
    id: hs
    property string value: ""
    property string caption: ""
    property color tint: root.fg
    signal clicked()
    implicitHeight: hsCol.implicitHeight
    implicitWidth: hsCol.implicitWidth
    HoverHandler { id: hsHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: hs.clicked() }
    Column {
      id: hsCol
      anchors.centerIn: parent
      spacing: Style.space(1)
      Text { anchors.horizontalCenter: parent.horizontalCenter; textFormat: Text.PlainText; text: hs.value; color: hs.tint; font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.title * 1.05); font.bold: true }
      Text { anchors.horizontalCenter: parent.horizontalCenter; textFormat: Text.PlainText; text: hs.caption; color: hsHover.hovered ? root.fg : root.dim; font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.95) }
    }
  }

  // Three flat figures with hairline dividers; no boxes.
  component FlatStats: RowLayout {
    id: fs
    property var items: []
    spacing: 0
    Repeater {
      model: fs.items
      RowLayout {
        required property var modelData
        required property int index
        Layout.fillWidth: true
        spacing: 0
        Rectangle { visible: index > 0; Layout.preferredWidth: 1; Layout.preferredHeight: Style.space(40); color: root.line }
        Column {
          Layout.fillWidth: true
          spacing: Style.space(1)
          Text { anchors.horizontalCenter: parent.horizontalCenter; textFormat: Text.PlainText; text: modelData[0]; color: root.fg; font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.title * 1.15); font.bold: true }
          Text { anchors.horizontalCenter: parent.horizontalCenter; textFormat: Text.PlainText; text: modelData[1]; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Text { anchors.horizontalCenter: parent.horizontalCenter; visible: modelData[2] !== ""; textFormat: Text.PlainText; text: modelData[2]; color: root.faint; font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.9) }
        }
      }
    }
  }

  // Session ring: track, a gauge-coloured arc that sweeps to its value, % inside.
  component Ring: Item {
    id: rg
    property real pct: 0
    property bool known: false
    property string caption: ""
    property real shown: 0
    signal clicked()
    onPctChanged: shown = pct
    Component.onCompleted: shown = pct
    Behavior on shown { NumberAnimation { duration: Style.duration(700); easing.type: Easing.OutCubic } }
    onShownChanged: arc.requestPaint()
    readonly property color tone: root.gauge(pct)
    onToneChanged: arc.requestPaint()
    HoverHandler { cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: rg.clicked() }
    Canvas {
      id: arc
      anchors.fill: parent
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var lw = Math.max(3, width * 0.085)
        var r = Math.min(width, height) / 2 - lw / 2 - 1
        var cx = width / 2, cy = height / 2
        ctx.lineWidth = lw
        ctx.lineCap = "round"
        ctx.strokeStyle = Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.1)
        ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.stroke()
        if (!rg.known || rg.shown <= 0) return
        ctx.strokeStyle = rg.tone
        ctx.beginPath()
        ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.min(1, rg.shown / 100))
        ctx.stroke()
      }
    }
    Column {
      anchors.centerIn: parent
      spacing: -Style.space(2)
      Text { anchors.horizontalCenter: parent.horizontalCenter; textFormat: Text.PlainText; text: rg.known ? Math.round(rg.shown) + "%" : "–"; color: rg.known ? rg.tone : root.dim; font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.body * 1.05); font.bold: true }
      Text { anchors.horizontalCenter: parent.horizontalCenter; textFormat: Text.PlainText; text: rg.caption; color: root.dim; font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.8) }
    }
  }

  // Activity over the last 30 minutes, filled under the line.
  component Spark: Canvas {
    id: spk
    property var buckets: []
    property color tint: root.accent
    onBucketsChanged: requestPaint()
    onTintChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var pts = Model.sparkPoints(buckets)
      if (pts.length < 2) return
      var h = height - 2, w = width
      ctx.beginPath()
      ctx.moveTo(0, height)
      for (var i = 0; i < pts.length; i++) ctx.lineTo(pts[i].x * w, 1 + h - pts[i].y * h)
      ctx.lineTo(w, height)
      ctx.closePath()
      ctx.fillStyle = Qt.rgba(tint.r, tint.g, tint.b, 0.18)
      ctx.fill()
      ctx.beginPath()
      for (var j = 0; j < pts.length; j++) {
        var x = pts[j].x * w, y = 1 + h - pts[j].y * h
        if (j === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
      }
      ctx.lineWidth = 1.4
      ctx.strokeStyle = tint
      ctx.stroke()
    }
  }

  component Thin: Rectangle {
    property real ratio: 0
    property color tint: root.accent
    height: Style.space(4); radius: height / 2
    color: root.line
    Rectangle {
      width: Math.max(parent.height, parent.width * Math.max(0, Math.min(1, parent.ratio)))
      height: parent.height; radius: parent.radius; color: parent.tint
      Behavior on width { NumberAnimation { duration: Style.duration(400); easing.type: Easing.OutCubic } }
    }
  }

  component BarLine: Column {
    id: bl
    property string label: ""
    property string value: ""
    property real ratio: 0
    property color tint: root.accent
    spacing: Style.space(4)
    RowLayout {
      width: parent.width
      Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: bl.label; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight }
      Text { textFormat: Text.PlainText; text: bl.value; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    }
    Thin { width: parent.width; ratio: bl.ratio; tint: bl.tint }
  }

  // One plan limit: big %, countdown, a thermometer bar with an even-pace marker.
  component LimitMeter: Column {
    id: lm
    property var w: ({})
    readonly property var p: Model.pace(w, root.now)
    // The recent burn rate from saved readings; null until there are enough.
    readonly property var f: Model.forecast(((root.usage.history || {})[w.id]) || [], w, root.now)
    readonly property string runsOut: f
      ? (f.beforeReset ? "at this rate: 100% " + (f.hitsAt - root.now < 86400 && new Date(f.hitsAt * 1000).getDate() === new Date(root.now * 1000).getDate()
                                                 ? Qt.formatDateTime(new Date(f.hitsAt * 1000), "HH:mm")
                                                 : Qt.formatDateTime(new Date(f.hitsAt * 1000), "ddd HH:mm")) : "")
      : (p.runsOutBeforeReset ? "runs out in " + Model.duration(p.runsOutIn) : "")
    readonly property color c: root.gauge(w.pct)
    readonly property string scope: String(w.id || "").indexOf("model:") === 0 ? String(w.id).slice(6) : ""
    spacing: Style.space(7)
    RowLayout {
      width: parent.width
      spacing: Style.space(8)
      Text { textFormat: Text.PlainText; text: lm.scope ? "Weekly" : lm.w.label; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
      ModelTag { visible: lm.scope !== ""; model: lm.scope }
      Text {
        textFormat: Text.PlainText
        text: lm.w.windowSec === 18000 ? "5-hour window" : "7-day window"
        color: root.faint; font.family: root.fontFamily; font.pixelSize: Style.font.caption
      }
      Item { Layout.fillWidth: true }
      Text { textFormat: Text.PlainText; text: Math.round(lm.w.pct) + "%"; color: lm.c; font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.title * 1.1); font.bold: true }
    }
    Item {
      width: parent.width
      height: Style.space(8)
      Rectangle {
        anchors.fill: parent
        radius: root.radius
        opacity: 0.16
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: root.pal.green }
          GradientStop { position: 0.5; color: root.pal.yellow }
          GradientStop { position: 0.75; color: root.pal.orange }
          GradientStop { position: 0.9; color: root.pal.red }
        }
      }
      Item {
        width: parent.width * Math.max(0, Math.min(1, lm.w.pct / 100))
        height: parent.height
        clip: true
        Behavior on width { NumberAnimation { duration: Style.duration(600); easing.type: Easing.OutCubic } }
        Rectangle {
          width: lm.width; height: parent.height
          radius: root.radius
          gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: root.pal.green }
            GradientStop { position: 0.5; color: root.pal.yellow }
            GradientStop { position: 0.75; color: root.pal.orange }
            GradientStop { position: 0.9; color: root.pal.red }
          }
        }
      }
      Rectangle {
        visible: lm.p.state !== "unknown"
        x: parent.width * lm.p.elapsed / 100 - width / 2
        y: -Style.space(3)
        width: 2; height: parent.height + Style.space(6)
        radius: 1
        color: root.fg
        opacity: 0.85
      }
    }
    RowLayout {
      width: parent.width
      Text {
        textFormat: Text.PlainText
        text: lm.p.state === "unknown" ? "" : lm.p.arrow + " " + (lm.p.state === "on" ? "on pace"
              : Math.abs(lm.p.delta) + " pts " + (lm.p.delta > 0 ? "ahead" : "under"))
              + (lm.runsOut ? "  ·  " + lm.runsOut : "")
        color: lm.p.state === "hot" ? root.urgentColor : lm.p.state === "ahead" ? root.pal.yellow : root.dim
        font.family: root.fontFamily; font.pixelSize: Style.font.caption
      }
      Item { Layout.fillWidth: true }
      Text {
        textFormat: Text.PlainText
        text: lm.w.resetsAt ? "resets in " + Model.duration(lm.w.resetsAt - root.now) : ""
        color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
      }
    }
    Text {
      readonly property var a: Model.dailyAllowance(lm.w, root.now)
      visible: a !== null
      width: parent.width
      textFormat: Text.PlainText
      text: a ? "≈" + (a.perDay < 1 ? "<1" : Math.floor(a.perDay)) + "% a day keeps you within this limit" : ""
      color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  // Folders to start a session in: pinned first. Left click picks, right click pins.
  component FolderStrip: Flickable {
    id: fstrip
    property string chosen: ""
    property bool withHome: false
    signal picked(string cwd)
    readonly property var items: withHome
      ? [{ cwd: root.home, project: "~", pinned: root.isPinned(root.home) }].concat(root.folders.filter(function(f) { return f.cwd !== root.home }))
      : root.folders
    height: fsRow.implicitHeight
    contentWidth: fsRow.implicitWidth
    flickableDirection: Flickable.HorizontalFlick
    boundsBehavior: Flickable.StopAtBounds
    clip: true
    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: function(event) {
        var d = event.angleDelta.x !== 0 ? event.angleDelta.x : event.angleDelta.y
        fstrip.contentX = Math.max(0, Math.min(Math.max(0, fstrip.contentWidth - fstrip.width), fstrip.contentX - d * 0.6))
      }
    }
    Row {
      id: fsRow
      spacing: Style.space(4)
      Repeater {
        model: fstrip.items.slice(0, 16)
        Rectangle {
          required property var modelData
          readonly property bool isChosen: fstrip.chosen === modelData.cwd
          implicitWidth: fRow.implicitWidth + Style.space(14)
          implicitHeight: fRow.implicitHeight + Style.space(10)
          radius: root.radius
          color: isChosen ? Qt.alpha(root.accent, 0.12) : (fHover.hovered ? root.subtle : "transparent")
          border.width: 1
          border.color: isChosen ? root.accent : fHover.hovered ? Qt.alpha(root.projectColor(modelData.project), 0.6) : root.line
          HoverHandler { id: fHover; cursorShape: Qt.PointingHandCursor }
          TapHandler { acceptedButtons: Qt.LeftButton; onTapped: fstrip.picked(modelData.cwd) }
          TapHandler { acceptedButtons: Qt.RightButton; onTapped: root.togglePin(modelData.cwd) }
          Row {
            id: fRow
            anchors.centerIn: parent
            spacing: Style.space(7)
            ProjectTile { name: modelData.project; size: Style.space(20) }
            Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: modelData.project; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            Text {
              visible: !!modelData.pinned
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText; text: "\u{f0403}"; color: root.accent
              font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.9)
            }
          }
          Hint { shown: fHover.hovered; label: Model.shortPath(modelData.cwd, root.home); anchors.top: parent.bottom; anchors.topMargin: Style.space(3); anchors.left: parent.left }
        }
      }
    }
  }

  // A background job (claude --bg / daemon).
  component JobRow: Rectangle {
    id: jr
    property var j: ({})
    readonly property string st: String(j.state || "")
    readonly property color tint: /blocked|failed|error/.test(st) ? root.urgentColor
                                 : /done|completed|finished/.test(st) ? root.pal.green : root.accent
    implicitHeight: jrBody.implicitHeight + Style.space(16)
    radius: root.radius
    color: jrHover.hovered ? root.subtle : "transparent"
    HoverHandler { id: jrHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: root.resume({ sessionId: jr.j.sessionId, cwd: jr.j.cwd }) }
    RowLayout {
      id: jrBody
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10); anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)
      ProjectTile { Layout.alignment: Qt.AlignTop; name: jr.j.project; size: Style.space(28) }
      Column {
        Layout.fillWidth: true
        spacing: Style.space(3)
        RowLayout {
          width: parent.width
          spacing: Style.space(8)
          Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: jr.j.name; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true; elide: Text.ElideRight }
          Tag { label: jr.st; tint: jr.tint }
        }
        Text {
          width: parent.width
          visible: text !== ""
          textFormat: Text.PlainText
          text: jr.j.needs || jr.j.detail || jr.j.intent || ""
          color: /blocked|failed|error/.test(jr.st) ? root.urgentColor : root.dim
          font.family: root.fontFamily; font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          text: jr.j.project + "  ·  " + Model.tokens(jr.j.tokens) + " tok  ·  updated " + Model.ago(jr.j.updatedAt, root.now) + (jrHover.hovered ? "  ·  click to resume" : "")
          color: root.faint; font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.92)
        }
      }
    }
  }

  // One health check: a status glyph, a label, a detail, an optional action.
  component HealthLine: RowLayout {
    id: hl
    property string glyph: ""
    property string level: "ok"     // ok / warn / bad / off
    property string label: ""
    property string detail: ""
    property string actionLabel: ""
    signal action()
    width: parent ? parent.width : 0
    spacing: Style.space(10)
    readonly property color tint: level === "bad" ? root.urgentColor : level === "warn" ? root.accent : level === "off" ? root.faint : root.pal.green
    Rectangle {
      Layout.preferredWidth: Style.space(26); Layout.preferredHeight: Style.space(26)
      radius: root.radius
      color: Qt.alpha(hl.tint, 0.14)
      Text { anchors.centerIn: parent; textFormat: Text.PlainText; text: hl.glyph; color: hl.tint; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
    }
    Column {
      Layout.fillWidth: true
      spacing: Style.space(1)
      Text { textFormat: Text.PlainText; text: hl.label; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
      Text { width: parent.width; visible: hl.detail !== ""; textFormat: Text.PlainText; text: hl.detail; color: hl.level === "bad" || hl.level === "warn" ? hl.tint : root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
    }
    Tag { visible: hl.actionLabel !== ""; label: hl.actionLabel; tint: root.accent; clickable: true; onClicked: hl.action() }
  }

  // One event's sound: current choice with ▶, and a picker that opens below.
  component SoundRow: Column {
    id: sw
    property string kind: "finished"
    property string title: ""
    property string key: ""
    property string value: "claude"
    readonly property bool opened: root.soundPicker === kind
    spacing: Style.space(6)
    Rectangle {
      width: parent.width
      implicitHeight: swRow.implicitHeight + Style.space(12)
      radius: root.radius
      color: swHover.hovered || sw.opened ? root.subtle : "transparent"
      HoverHandler { id: swHover; cursorShape: Qt.PointingHandCursor }
      TapHandler { onTapped: root.soundPicker = sw.opened ? "" : sw.kind }
      RowLayout {
        id: swRow
        anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
        spacing: Style.space(10)
        Text { textFormat: Text.PlainText; text: sw.title; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true; Layout.preferredWidth: Style.space(130) }
        Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: root.soundLabel(sw.value); color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
        RowAction { glyph: "\u{f040a}"; hint: "Play"; onClicked: root.previewSound(sw.value, sw.kind) }
        Text { textFormat: Text.PlainText; text: sw.opened ? "\u{f0143}" : "\u{f0140}"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
      }
    }
    Flow {
      width: parent.width
      visible: sw.opened
      spacing: Style.space(4)
      leftPadding: Style.space(8)
      Repeater {
        model: root.ownSounds.map(function(o) { return o[0] }).concat(root.systemSounds).concat(["none"])
        Rectangle {
          required property var modelData
          readonly property bool chosen: sw.value === modelData
          readonly property bool own: String(modelData).indexOf("claude") === 0
          implicitWidth: optRow.implicitWidth + Style.space(14)
          implicitHeight: optRow.implicitHeight + Style.space(8)
          radius: root.radius
          color: chosen ? Qt.alpha(root.accent, 0.14) : optHover.hovered ? root.subtle : "transparent"
          border.width: 1
          border.color: chosen ? root.accent : root.line
          HoverHandler { id: optHover; cursorShape: Qt.PointingHandCursor }
          // Click: hear it and choose it.
          TapHandler { onTapped: { root.previewSound(modelData, sw.kind); root.setSetting(sw.key, modelData) } }
          Row {
            id: optRow
            anchors.centerIn: parent
            spacing: Style.space(5)
            Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: modelData === "none" ? "\u{f075f}" : (chosen ? "\u{f012c}" : "\u{f040a}"); color: chosen || own ? root.accent : root.dim; font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.9) }
            Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: root.soundLabel(modelData); color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: own }
          }
        }
      }
    }
  }

  // An alert card on screen.
  component AlertCard: Rectangle {
    id: ac
    property var e: ({})
    property bool leaving: false
    property real slide: Style.space(48)
    property real elapsed: 0
    readonly property real ttl: 8000
    readonly property color tone: root.toneColor(e.tone)
    width: Style.space(380)
    implicitHeight: acBody.implicitHeight + Style.space(24)
    radius: root.radius
    color: Commons.Color.popups.background
    border.width: 1
    border.color: Qt.alpha(ac.tone, acHover.hovered ? 0.7 : 0.4)
    opacity: 0
    transform: Translate { x: ac.slide }
    clip: true

    Component.onCompleted: { enterAnim.start(); markPulse.start() }
    ParallelAnimation {
      id: enterAnim
      NumberAnimation { target: ac; property: "slide"; to: 0; duration: Style.duration(260); easing.type: Easing.OutCubic }
      NumberAnimation { target: ac; property: "opacity"; to: 1; duration: Style.duration(200); easing.type: Easing.OutCubic }
    }
    function leave() {
      if (leaving) return
      leaving = true
      exitAnim.start()
    }
    SequentialAnimation {
      id: exitAnim
      ParallelAnimation {
        NumberAnimation { target: ac; property: "slide"; to: Style.space(48); duration: Style.duration(180); easing.type: Easing.InCubic }
        NumberAnimation { target: ac; property: "opacity"; to: 0; duration: Style.duration(180) }
      }
      ScriptAction { script: root.dismissCard(ac.e.id) }
    }

    HoverHandler { id: acHover }
    // Countdown: paused while hovered; sticky cards wait (up to 10 minutes).
    Timer {
      interval: 50; repeat: true
      running: !ac.leaving && !acHover.hovered
      onTriggered: {
        ac.elapsed += interval
        if ((!ac.e.sticky && ac.elapsed >= ac.ttl) || ac.elapsed >= 600000) ac.leave()
      }
    }

    // Event-colour edge.
    Rectangle { width: Style.space(3); height: parent.height; color: ac.tone }

    RowLayout {
      id: acBody
      anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
      anchors.leftMargin: Style.space(14); anchors.rightMargin: Style.space(10); anchors.topMargin: Style.space(12)
      spacing: Style.space(12)

      Item {
        Layout.alignment: Qt.AlignTop
        Layout.preferredWidth: Style.space(38); Layout.preferredHeight: Style.space(38)
        ProjectTile { anchors.fill: parent; name: ac.e.project || "?"; size: Style.space(38) }
        // The Claude mark in the event colour, pulsing as the card arrives.
        Rectangle {
          id: mark
          width: Style.space(18); height: width; radius: width / 2
          x: parent.width - width + Style.space(5); y: -Style.space(5)
          color: Commons.Color.popups.background
          border.width: 1; border.color: Qt.alpha(ac.tone, 0.6)
          Text { anchors.centerIn: parent; textFormat: Text.PlainText; text: root.claudeGlyph; color: ac.tone; font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.95) }
          SequentialAnimation {
            id: markPulse
            loops: 2
            NumberAnimation { target: mark; property: "scale"; to: 1.35; duration: Style.duration(220); easing.type: Easing.OutCubic }
            NumberAnimation { target: mark; property: "scale"; to: 1.0; duration: Style.duration(260); easing.type: Easing.InOutSine }
          }
        }
      }

      Column {
        Layout.fillWidth: true
        spacing: Style.space(4)
        RowLayout {
          width: parent.width
          spacing: Style.space(6)
          Text { textFormat: Text.PlainText; text: ac.e.glyph || ""; color: ac.tone; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Text { textFormat: Text.PlainText; text: ac.e.title || ac.e.headline || ""; color: ac.tone; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
          Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: ac.e.project ? "·  " + ac.e.project : ""; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight }
          RowAction { glyph: "\u{f0156}"; hint: "Dismiss"; onClicked: ac.leave() }
        }
        Text {
          width: parent.width
          visible: text !== ""
          textFormat: Text.PlainText
          text: ac.e.body || ""
          color: Qt.alpha(root.fg, 0.85)
          font.family: root.fontFamily; font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
        }
        Row {
          spacing: Style.space(10)
          visible: (ac.e.model || "") !== "" || (ac.e.tokens || 0) > 0
          ModelTag { model: ac.e.model || "" }
          Meta { visible: (ac.e.tokens || 0) > 0; glyph: "\u{f0bef}"; text: Model.tokens(ac.e.tokens) }
          Meta { visible: root.showCost && (ac.e.cost || 0) > 0; glyph: "\u{f01c1}"; text: Model.cost(ac.e.cost).replace("$", "") }
        }
        Row {
          topPadding: Style.space(4)
          spacing: Style.space(6)
          Tag { visible: (ac.e.button || "") !== ""; label: ac.e.button || ""; tint: ac.tone; clickable: true; onClicked: root.actOn(ac.e) }
          Tag { label: "Open panel"; tint: root.dim; clickable: true; onClicked: root.openFor(ac.e) }
        }
      }
    }

    // Time left, in the event colour (sticky cards show a still, full line).
    Rectangle {
      anchors.bottom: parent.bottom
      height: 2
      width: ac.e.sticky ? parent.width : parent.width * Math.max(0, 1 - ac.elapsed / ac.ttl)
      color: Qt.alpha(ac.tone, ac.e.sticky ? 0.5 : 0.8)
    }
  }

  // One entry in the alert log.
  component AlertRow: Rectangle {
    id: ar
    property var e: ({})
    readonly property color tone: root.toneColor(e.tone)
    implicitHeight: arBody.implicitHeight + Style.space(14)
    radius: root.radius
    color: arHover.hovered ? root.subtle : "transparent"
    HoverHandler { id: arHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: root.actOn(ar.e) }
    Rectangle { x: 0; anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.topMargin: Style.space(8); anchors.bottomMargin: Style.space(8); width: Style.space(3); radius: 1; color: ar.tone }
    RowLayout {
      id: arBody
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12); anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)
      ProjectTile { Layout.alignment: Qt.AlignTop; name: ar.e.project || "?"; size: Style.space(26) }
      Column {
        Layout.fillWidth: true
        spacing: Style.space(2)
        RowLayout {
          width: parent.width
          spacing: Style.space(6)
          Text { textFormat: Text.PlainText; text: ar.e.title || ar.e.headline || ""; color: ar.tone; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
          Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: ar.e.project ? "·  " + ar.e.project : ""; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight }
          Text { textFormat: Text.PlainText; text: Model.ago(ar.e.ts, root.now); color: root.faint; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        }
        Text { width: parent.width; visible: (ar.e.body || "") !== ""; textFormat: Text.PlainText; text: ar.e.body || ""; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
      }
    }
  }

  // One live session.
  component SessionRow: Rectangle {
    id: sr
    property var s: ({})
    property int rowIndex: 0
    readonly property bool isWaiting: s.status === "waiting"
    readonly property bool blocked: isWaiting && !!s.approval
    readonly property color stateTint: blocked ? root.urgentColor : root.accent
    readonly property var modeTag: Model.modeInfo(s.mode)
    readonly property bool ctxHot: ctxRatio * 100 >= root.contextWarnPct
    readonly property bool hovered: srHover.hovered
    readonly property bool sel: root.selected === rowIndex && root.tab === 0
    readonly property bool open: hovered || sel
    readonly property real ctxRatio: Math.min(1, (s.context || 0) / Model.contextLimit(s.model))
    readonly property var sub: s.sub || ({ running: 0, done: 0, tokens: 0, cost: 0, active: [] })
    readonly property color tone: root.projectColor(s.project)
    implicitHeight: srBody.implicitHeight + Style.space(20)
    radius: root.radius
    color: open ? root.subtle : "transparent"
    border.width: sel ? 1 : 0
    border.color: Qt.alpha(root.accent, 0.45)
    Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    HoverHandler { id: srHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: root.focusSession(sr.s) }

    // Waiting for you: an accent edge; red while blocked on an approval.
    Rectangle {
      visible: sr.isWaiting
      x: 0; anchors.top: parent.top; anchors.bottom: parent.bottom
      anchors.topMargin: Style.space(10); anchors.bottomMargin: Style.space(10)
      width: Style.space(3); radius: width / 2
      color: sr.stateTint
    }

    RowLayout {
      id: srBody
      anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
      anchors.leftMargin: Style.space(10); anchors.rightMargin: Style.space(10); anchors.topMargin: Style.space(10)
      spacing: Style.space(12)

      ProjectTile { Layout.alignment: Qt.AlignTop; name: sr.s.project }

      Column {
        Layout.fillWidth: true
        spacing: Style.space(5)

        // project · status (or actions on hover)
        Item {
          width: parent.width
          height: Math.max(nameText.implicitHeight, Style.space(22))
          Text {
            id: nameText
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            width: parent.width - (sr.open ? actions.width : statusText.implicitWidth) - Style.space(8)
            textFormat: Text.PlainText
            text: sr.s.project
            color: root.fg
            font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true
            elide: Text.ElideRight
          }
          Row {
            id: statusText
            visible: !sr.open
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(5)
            readonly property real implicitWidth2: 0
            Text {
              textFormat: Text.PlainText
              text: sr.blocked ? "\u{f0026}" : sr.isWaiting ? "\u{f0e1e}" : "\u{f0772}"
              color: sr.isWaiting ? sr.stateTint : root.dim
              font.family: root.fontFamily; font.pixelSize: Style.font.caption
              RotationAnimation on rotation { running: !sr.isWaiting; from: 0; to: 360; duration: 1400; loops: Animation.Infinite }
            }
            Text {
              textFormat: Text.PlainText
              text: sr.blocked ? Model.waitLabel(sr.s).replace(/ · .*/, "") + " · " + Model.duration(root.now - sr.s.since)
                    : (sr.isWaiting ? "waiting " : "working ") + Model.duration(root.now - sr.s.since)
              color: sr.isWaiting ? sr.stateTint : root.dim
              font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: sr.isWaiting
            }
          }
          Row {
            id: actions
            visible: sr.open
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            RowAction { glyph: "\u{f018f}"; hint: "Copy session ID"; done: root.copiedId === sr.s.sessionId; onClicked: root.copyText(sr.s.sessionId) }
            RowAction { glyph: "\u{f0770}"; hint: "Open folder"; onClicked: root.openFolder(sr.s.cwd) }
            RowAction { glyph: "\u{f0a1e}"; hint: "Open in editor"; onClicked: root.openEditor(sr.s.cwd) }
            RowAction { glyph: root.isPinned(sr.s.cwd) ? "\u{f0403}" : "\u{f0931}"; hint: root.isPinned(sr.s.cwd) ? "Unpin project" : "Pin project"; onClicked: root.togglePin(sr.s.cwd) }
            RowAction { glyph: "\u{f0415}"; hint: "New session here"; onClicked: root.openLauncher(sr.s.cwd) }
            RowAction { glyph: "\u{f0b2a}"; hint: "Go to terminal"; onClicked: root.focusSession(sr.s) }
          }
        }

        Text {
          width: parent.width
          visible: text !== ""
          textFormat: Text.PlainText
          text: sr.s.title || sr.s.name || ""
          color: Qt.alpha(root.fg, 0.82)
          font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        // What it is doing now, or what it is waiting on you for.
        Rectangle {
          width: parent.width
          visible: !!sr.s.doing || sr.blocked
          implicitHeight: doingRow.implicitHeight + (sr.blocked ? Style.space(8) : 0)
          radius: root.radius
          color: sr.blocked ? Qt.alpha(root.urgentColor, 0.12) : "transparent"
          Row {
            id: doingRow
            anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: sr.blocked ? Style.space(8) : 0
            spacing: Style.space(6)
            readonly property var call: sr.blocked ? sr.s.approval : sr.s.doing
            Text {
              textFormat: Text.PlainText
              text: Model.toolGlyph(doingRow.call ? doingRow.call.tool : "")
              color: sr.blocked ? root.urgentColor : Qt.alpha(root.accent, 0.9)
              font.family: root.fontFamily; font.pixelSize: Style.font.caption
            }
            Text {
              width: parent.width - Style.space(30)
              textFormat: Text.PlainText
              text: sr.blocked ? (doingRow.call && doingRow.call.detail
                                    ? (doingRow.call.tool ? doingRow.call.tool.replace(/^mcp__/, "") + ":  " : "") + doingRow.call.detail
                                    : "Answer in the terminal  ·  click to jump there")
                    : Model.doingLabel(doingRow.call)
              color: sr.blocked ? root.urgentColor : root.dim
              font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: sr.blocked
              elide: Text.ElideRight
            }
          }
        }

        // model · branch · tokens · cost
        Flow {
          width: parent.width
          spacing: Style.space(10)
          Repeater {
            model: sr.s.models && sr.s.models.length ? sr.s.models : (sr.s.modelName ? [sr.s.modelName] : [])
            ModelTag { required property var modelData; model: modelData }
          }
          Tag {
            visible: sr.modeTag.label !== ""
            label: sr.modeTag.label
            tint: sr.modeTag.level === "danger" ? root.urgentColor : sr.modeTag.level === "warn" ? root.pal.yellow : root.pal.blue
          }
          Meta { visible: (sr.s.branch || "") !== ""; glyph: "\u{e725}"; text: sr.s.branch }
          Meta { visible: !!sr.s.outdated; glyph: "\u{f0026}"; text: "old version " + sr.s.version }
          Meta { glyph: "\u{f0bef}"; text: Model.tokens(sr.s.tokens + sr.sub.tokens) }
          Meta { visible: root.showCost; glyph: "\u{f01c1}"; text: Model.cost(sr.s.cost + sr.sub.cost).replace("$", "") }
          Meta { visible: sr.open; glyph: "\u{f0369}"; text: sr.s.turns + " replies" }
        }

        // context · activity
        RowLayout {
          width: parent.width
          spacing: Style.space(12)
          Column {
            Layout.fillWidth: true
            spacing: Style.space(3)
            Thin { width: parent.width; height: Style.space(3); ratio: sr.ctxRatio; tint: sr.ctxHot ? root.urgentColor : root.gauge(sr.ctxRatio * 100) }
            Text {
              textFormat: Text.PlainText
              text: "context " + Math.round(sr.ctxRatio * 100) + "%  ·  " + Model.tokens(sr.s.context) + (sr.ctxHot ? "  ·  time to /compact" : "")
              color: sr.ctxHot ? root.urgentColor : root.faint
              font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.9); font.bold: sr.ctxHot
            }
          }
          Column {
            spacing: Style.space(3)
            Spark { width: Style.space(96); height: Style.space(18); buckets: sr.s.spark || []; tint: sr.tone }
            Text {
              anchors.right: parent.right
              textFormat: Text.PlainText
              text: (sr.s.rate ? Model.tokens(sr.s.rate) : "0") + " tok/min"
              color: root.faint; font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.9)
            }
          }
        }

        // Subagents.
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: sr.sub.running + sr.sub.done > 0 || sr.s.agentCalls > 0
          Text {
            textFormat: Text.PlainText
            text: "\u{f0645}  " + (sr.sub.running > 0 ? sr.sub.running + " subagent" + (sr.sub.running > 1 ? "s" : "") + " running" : "subagents idle")
                  + (sr.sub.done ? "  ·  " + sr.sub.done + " done" : "")
                  + (sr.sub.tokens ? "  ·  " + Model.tokens(sr.sub.tokens) + (root.showCost ? "  " + Model.cost(sr.sub.cost) : "") : "")
            color: sr.sub.running > 0 ? root.accent : root.dim
            font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: sr.sub.running > 0
          }
          Repeater {
            model: sr.sub.active || []
            Text {
              required property var modelData
              width: parent.width
              leftPadding: Style.space(18)
              textFormat: Text.PlainText
              text: modelData.type + " · " + modelData.desc
              color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        Text {
          width: parent.width
          visible: sr.open && (sr.s.prompt || "") !== ""
          textFormat: Text.PlainText
          text: "\u{f0b7a}  " + sr.s.prompt
          color: root.dim
          font.family: root.fontFamily; font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
          maximumLineCount: 4
          elide: Text.ElideRight
        }
      }
    }
  }

  component Meta: Row {
    id: mt
    property string glyph: ""
    property string text: ""
    spacing: Style.space(4)
    Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: mt.glyph; color: root.faint; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: mt.text; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
  }

  component ProjectRow: RowLayout {
    id: pr
    property var p: ({})
    readonly property real share: root.stats && root.stats.week.tokens ? p.tokens / root.stats.week.tokens : 0
    readonly property color tone: root.projectColor(p.project)
    spacing: Style.space(10)
    ProjectTile { Layout.alignment: Qt.AlignTop; name: pr.p.project; size: Style.space(28) }
    Column {
      Layout.fillWidth: true
      spacing: Style.space(4)
      RowLayout {
        width: parent.width
        spacing: Style.space(8)
        Text { Layout.fillWidth: true; textFormat: Text.PlainText; text: pr.p.project; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true; elide: Text.ElideRight }
        Text { textFormat: Text.PlainText; text: root.showCost ? Model.cost(pr.p.cost) : Model.tokens(pr.p.tokens); color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }
      }
      Thin { width: parent.width; ratio: pr.share; tint: pr.tone }
      Row {
        spacing: Style.space(8)
        Repeater { model: pr.p.models; ModelTag { required property var modelData; model: modelData } }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: pr.p.sessions + (pr.p.sessions === 1 ? " session" : " sessions") + "  ·  " + Model.tokens(pr.p.tokens) + " tok"
                + (pr.p.subTokens ? "  ·  subagents " + Math.round(100 * pr.p.subTokens / Math.max(1, pr.p.tokens)) + "%" : "")
          color: root.faint; font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.92)
        }
      }
    }
  }

  component HistoryRow: Rectangle {
    id: hr
    property var r: ({})
    property int rowIndex: 0
    readonly property bool sel: root.selected === rowIndex && root.tab === 3
    readonly property bool open: hrHover.hovered || sel
    implicitHeight: hrBody.implicitHeight + Style.space(16)
    radius: root.radius
    color: open ? root.subtle : "transparent"
    border.width: sel ? 1 : 0
    border.color: Qt.alpha(root.accent, 0.45)
    Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    HoverHandler { id: hrHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: root.resume(hr.r) }
    RowLayout {
      id: hrBody
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10); anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)
      ProjectTile { Layout.alignment: Qt.AlignTop; name: hr.r.project; size: Style.space(28) }
      Column {
        Layout.fillWidth: true
        spacing: Style.space(3)
        Item {
          width: parent.width
          height: Math.max(hTitle.implicitHeight, Style.space(22))
          Text {
            id: hTitle
            anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
            width: parent.width - (hr.open ? hActions.width : hAgo.implicitWidth) - Style.space(8)
            textFormat: Text.PlainText
            text: hr.r.title || hr.r.prompt || "Untitled"
            color: root.fg
            font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
            elide: Text.ElideRight
          }
          Text {
            id: hAgo
            visible: !hr.open
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: Model.ago(hr.r.last, root.now)
            color: root.faint; font.family: root.fontFamily; font.pixelSize: Style.font.caption
          }
          Row {
            id: hActions
            visible: hr.open
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            RowAction { glyph: "\u{f0e7a}"; hint: "Resume (Enter)"; onClicked: root.resume(hr.r) }
            RowAction { glyph: "\u{f018f}"; hint: "Copy session ID"; done: root.copiedId === hr.r.sessionId; onClicked: root.copyText(hr.r.sessionId) }
            RowAction { glyph: "\u{f0770}"; hint: "Open folder"; onClicked: root.openFolder(hr.r.cwd) }
          }
        }
        Text {
          width: parent.width
          visible: (hr.r.prompt || "") !== "" && hr.r.prompt !== hr.r.title
          textFormat: Text.PlainText
          text: hr.r.prompt
          color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
        Row {
          spacing: Style.space(10)
          Text { anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText; text: hr.r.project; color: root.projectColor(hr.r.project); font.family: root.fontFamily; font.pixelSize: Math.round(Style.font.caption * 0.92); font.bold: true }
          ModelTag { model: hr.r.model || "" }
          Meta { visible: (hr.r.branch || "") !== ""; glyph: "\u{e725}"; text: hr.r.branch || "" }
          Meta { glyph: "\u{f0bef}"; text: Model.tokens(hr.r.tokens) }
          Meta { visible: root.showCost; glyph: "\u{f01c1}"; text: Model.cost(hr.r.cost).replace("$", "") }
        }
      }
    }
  }
}
