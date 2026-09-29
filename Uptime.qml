import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "exeque.omarchy-http-uptime"

  // Config lives in its own file (edited from the panel or by hand):
  // { "interval": 300, "warnDays": 14, "slowMs": 2000, "targets": [{ "url": "...", "interval": 60, "slowMs": 800 }] }
  // A target without "interval" or "slowMs" uses the global one.
  readonly property string icon: "\uf21e"
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/http-uptime.json"
  property var config: ({ interval: 300, warnDays: 14, slowMs: 2000, targets: [] })

  readonly property var targets: config.targets || []
  property var results: ({})
  property var uptime: ({})
  // Detail view: URL shown, plus { checks: [{ time, up, status, code, ms }], series: { day|week|month: [pct] } }
  // loaded by detail.sh. Window sizes must match detail.sh.
  property string detailUrl: ""
  property var detail: null
  readonly property var windows: [
    { key: "day", label: "24h", size: 3600, count: 24 },
    { key: "week", label: "7d", size: 21600, count: 28 },
    { key: "month", label: "30d", size: 86400, count: 30 }
  ]
  property var nextDue: ({})
  property bool opened: false
  property bool editing: false
  // Drag-to-reorder state in settings: index being dragged and insertion index (0..targets.length).
  property int dragFrom: -1
  property int dragTo: -1
  // Settings grid: every settings row (header, URL rows, add row) uses these column widths so fields line up.
  readonly property real colGrip: Style.space(22)
  readonly property real colNumber: Style.spacing.numberFieldWidth
  readonly property real colAction: Style.space(56)
  readonly property real colGap: Style.space(8)

  readonly property var resultList: targets.map(t => results[t.url]).filter(r => r)
  readonly property int problems: resultList.filter(r => r.status !== "ok").length
  readonly property int worst: resultList.reduce((m, r) => Math.max(m, severity(r.status)), 0)
  // Theme yellow for degraded URLs; the shell's Color only exposes urgent, so read it from colors.toml.
  property color warning: "#e5c07b"
  property color good: "#98c379"
  // Display order: failing first, then degraded, then healthy; configured order within each group.
  readonly property var displayTargets: targets
    .map((t, i) => ({ t: t, i: i, s: severityOf(t.url) }))
    .sort((a, b) => b.s - a.s || a.i - b.i)
    .map(x => x.t)

  function severityOf(url) {
    return results[url] ? severity(results[url].status) : 0
  }

  // True when entry i of displayTargets starts a new severity group (down → slow/expiring → up).
  function sectionStart(i) {
    return i > 0 && i < displayTargets.length && severityOf(displayTargets[i].url) !== severityOf(displayTargets[i - 1].url)
  }

  function intervalFor(t) { return Math.max(10, t.interval || config.interval) }
  function slowFor(url) {
    var t = targets.find(t => t.url === url)
    return t && t.slowMs || config.slowMs
  }

  function save(patch) {
    config = Object.assign({}, config, patch)
    configFile.setText(JSON.stringify(config, null, 2) + "\n")
  }

  function validUrl(url) {
    return /^https?:\/\/\S+$/.test(url) && !targets.some(t => t.url === url)
  }

  function addTarget(url, interval, slowMs) {
    url = url.trim()
    if (!validUrl(url)) return false
    var t = { url: url }
    if (interval !== config.interval) t.interval = interval
    if (slowMs !== config.slowMs) t.slowMs = slowMs
    save({ targets: targets.concat([t]) })
    refresh(false)
    return true
  }

  // Saves a settings row's edits in one go. Only changed values are stored, so untouched ones keep
  // following the global defaults. Returns false (nothing saved) for an invalid or duplicate URL.
  // A changed URL takes its history along (rename.sh moves the file).
  function commitTarget(url, draftUrl, interval, slowMs) {
    draftUrl = draftUrl.trim()
    if (draftUrl !== url && !validUrl(draftUrl)) return false
    var t = targets.find(t => t.url === url)
    var patch = {}
    if (draftUrl !== url) patch.url = draftUrl
    if (interval !== intervalFor(t)) patch.interval = interval
    if (slowMs !== slowFor(url)) patch.slowMs = slowMs
    if (patch.url) {
      Quickshell.execDetached(["bash", Qt.resolvedUrl("rename.sh").toString().replace(/^file:\/\//, ""), url, draftUrl])
      var moved = Object.assign({}, uptime)
      moved[draftUrl] = moved[url]
      uptime = moved
    }
    save({ targets: targets.map(x => x.url === url ? Object.assign({}, x, patch) : x) })
    recheck([draftUrl])
    return true
  }

  // Status is decided when a check runs, so re-check after a threshold changes.
  function recheck(urls) {
    var next = Object.assign({}, nextDue)
    urls.forEach(u => next[u] = 0)
    nextDue = next
    refresh(false)
  }

  function moveTarget(from, to) {
    if (from < 0 || to < 0 || to === from || to === from + 1) return
    var list = targets.slice()
    list.splice(to > from ? to - 1 : to, 0, list.splice(from, 1)[0])
    save({ targets: list })
  }

  // Insertion index for a y position in the rows' column: before the first row whose middle is below y.
  function dropIndex(y) {
    for (var i = 0; i < targetRepeater.count; i++) {
      var item = targetRepeater.itemAt(i)
      if (y < item.y + item.height / 2) return i
    }
    return targetRepeater.count
  }

  function removeTarget(url) {
    save({ targets: targets.filter(t => t.url !== url) })
  }

  // There is one widget per monitor. The first instance leads: it runs the checks, writes the
  // history and sends notifications, then hands its results to the other instances.
  function peers() {
    return bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
  }

  function leader() {
    var items = peers()
    return items.length ? items[0] : root
  }

  // ponytail: checks run one batch at a time; URLs due while a batch runs wait for the next 10 s tick.
  function refresh(all) {
    if (leader() !== root) return leader().refresh(all)
    if (checkProc.running) return
    var now = Date.now()
    var due = targets.filter(t => all || (nextDue[t.url] || 0) <= now)
    if (!due.length) return
    var next = Object.assign({}, nextDue)
    due.forEach(t => next[t.url] = now + intervalFor(t) * 1000)
    nextDue = next
    checkProc.command = ["bash", Qt.resolvedUrl("check.sh").toString().replace(/^file:\/\//, "")].concat(due.map(t => t.url))
    checkProc.running = true
  }

  // 0 = healthy, 1 = degraded (slow, certificate expiring), 2 = failing (non-2xx, unreachable, invalid SSL)
  function severity(status) {
    return status === "ok" ? 0 : status === "slow" || status === "expiring" ? 1 : 2
  }

  // Title says what happened; the body starts with a dot in the state's colour (red down, yellow
  // degraded, green recovered; the body renders StyledText). Clicking the notification opens this
  // URL's detail view (see IpcHandler).
  function notify(r, recovered) {
    var level = severity(r.status)
    var host = r.url.replace(/^https?:\/\//, "").replace(/\/$/, "")
    var title = recovered ? "Recovered" : { slow: "Slow", expiring: "Certificate expiring", ssl: "SSL error" }[r.status] || "Down"
    var text = recovered ? "Responding normally (" + r.ms + " ms)" : r.detail
    var escaped = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "HTTP Uptime",
      "-u", level === 2 && !recovered ? "critical" : "normal",
      title + ": " + host, "<font color=\"" + (recovered ? good : severityColor(level)) + "\">●</font> " + escaped,
      "--exec", "omarchy-shell", moduleName, "showDetail", r.url])
  }




  function parse(text) {
    var next = Object.assign({}, results)
    var stats = {}
    text.trim().split("\n").filter(l => l).forEach(function(line) {
      var f = line.split("\t")
      if (f[0] === "stats") {
        stats[f[1]] = { day: f[2], week: f[3], month: f[4],
          downSince: f[5] ? parseInt(f[5]) * 1000 : 0, slowSince: f[6] ? parseInt(f[6]) * 1000 : 0 }
        return
      }
      var r = { url: f[0], status: f[1], code: f[2], ms: parseInt(f[3]), days: f[4] === "" ? null : parseInt(f[4]), detail: f[5] || "", checked: Date.now() }
      if (r.status === "ok" && r.days !== null && r.days < config.warnDays) {
        r.status = "expiring"
        r.detail = "Certificate expires in " + r.days + " days"
      } else if (r.status === "ok" && r.ms > slowFor(r.url)) {
        r.status = "slow"
        r.detail = "Response " + r.ms + " ms (limit " + slowFor(r.url) + " ms)"
      }
      // Notify when a URL gets worse than its previous check, and once when it recovers.
      var before = results[r.url] ? severity(results[r.url].status) : 0
      var after = severity(r.status)
      if (after > before) notify(r, false)
      else if (after === 0 && before > 0) notify(r, true)
      next[r.url] = r
    })
    results = next
    uptime = stats
    if (detailUrl) loadDetail()
    peers().forEach(function(w) {
      if (w === root) return
      w.results = next
      w.uptime = stats
    })
  }

  function severityColor(level) {
    return level === 0 ? Color.foreground : level === 1 ? warning : root.bar ? root.bar.urgent : Color.urgent
  }

  function statusColor(r) {
    return r ? severityColor(severity(r.status)) : Color.muted
  }

  // Status dots are green when healthy; text stays neutral so healthy rows don't compete for attention.
  function dotColor(r) {
    return r && severity(r.status) === 0 ? good : statusColor(r)
  }

  function summary(r) {
    if (!r) return "checking…"
    var since = sinceText(r)
    if (since) return r.detail + " · " + since
    var cert = r.days !== null ? " · cert " + r.days + "d" : ""
    return (r.status === "ok" ? "HTTP " + r.code : r.detail) + " · " + r.ms + " ms" + cert
  }

  // Bar tooltip: header with how many need attention, every URL in configured order with its state,
  // then average 24h uptime.
  function tooltipSummary() {
    if (!targets.length) return "HTTP Uptime: no URLs monitored\nClick to open, then add URLs in settings"
    var short = url => url.replace(/^https?:\/\//, "").replace(/\/$/, "")
    var lines = ["HTTP Uptime · " + (problems ? problems + " of " + targets.length + " need attention" : "all " + targets.length + " up")]
    displayTargets.forEach(function(t, i) {
      var r = results[t.url]
      if (sectionStart(i)) lines.push("──")
      if (!r) return lines.push("… " + short(t.url) + " — checking")
      var at = " · checked " + Qt.formatDateTime(new Date(r.checked), "HH:mm:ss")
      if (r.status === "ok") lines.push("✓ " + short(t.url) + " — " + r.code + " · " + r.ms + " ms" + at)
      else lines.push((severity(r.status) === 2 ? "✗ " : "! ") + short(t.url) + " — " + r.detail
        + (sinceText(r) ? " · " + sinceText(r) : "") + at)
    })
    var day = resultList.map(r => uptime[r.url] ? uptime[r.url].day : "").filter(v => v !== "")
    if (day.length) lines.push("24h uptime " + pctText((day.reduce((a, v) => a + parseFloat(v), 0) / day.length).toFixed(2)) + " avg")
    return lines.join("\n")
  }

  // "down since 14:02 (23 min)" / "slow since …" for the ongoing outage or slow streak of a result.
  function sinceText(r) {
    var key = severity(r.status) === 2 ? "downSince" : r.status === "slow" ? "slowSince" : ""
    var since = key && uptime[r.url] ? uptime[r.url][key] : 0
    if (!since) return ""
    var d = new Date(since)
    var today = d.toDateString() === new Date().toDateString()
    var mins = Math.max(0, Math.round((Date.now() - since) / 60000))
    var span = mins < 60 ? mins + " min" : mins < 1440 ? Math.floor(mins / 60) + " h " + (mins % 60) + " min"
      : Math.floor(mins / 1440) + " d " + Math.floor(mins % 1440 / 60) + " h"
    return (key === "downSince" ? "down" : "slow") + " since " + Qt.formatDateTime(d, today ? "HH:mm" : "d MMM HH:mm") + " (" + span + ")"
  }

  function pctText(v) {
    return v === undefined || v === "" ? "–" : parseFloat(v).toFixed(v === "100.00" || v === "0.00" ? 0 : 2) + "%"
  }

  function openUrl(url) {
    Quickshell.execDetached(["omarchy-launch-browser", url])
    close()
  }

  function showDetail(url) {
    detailUrl = url
    detail = null
    loadDetail()
  }

  function loadDetail() {
    detailProc.command = ["bash", Qt.resolvedUrl("detail.sh").toString().replace(/^file:\/\//, ""), detailUrl, String(slowFor(detailUrl))]
    detailProc.running = true
  }

  function parseDetail(text) {
    var d = { checks: [], series: {}, slow: {} }
    text.trim().split("\n").filter(l => l).forEach(function(line) {
      var f = line.split("\t")
      if (f[0] === "check") {
        // Lines written before status/code/ms were recorded only carry up/down.
        var status = f[3] || (f[2] === "1" ? "ok" : "down")
        var ms = f[5] ? parseInt(f[5]) : null
        if (status === "ok" && ms !== null && ms > slowFor(detailUrl)) status = "slow"
        d.checks.push({ time: parseInt(f[1]) * 1000, status: status, code: f[4] || "", ms: ms })
      } else if (f[0] === "series") {
        d.series[f[1]] = f.slice(2)
      } else if (f[0] === "slow") {
        d.slow[f[1]] = f.slice(2)
      }
    })
    detail = d
  }

  function statusLabel(status) {
    return { ok: "Up", slow: "Slow", down: "Down", ssl: "SSL error" }[status] || status
  }

  function timeText(ms) {
    var d = new Date(ms)
    return Qt.formatDateTime(d, d.toDateString() === new Date().toDateString() ? "HH:mm:ss" : "d MMM HH:mm")
  }

  function screenName() {
    var w = root.QsWindow.window
    return w && w.screen ? String(w.screen.name) : ""
  }

  function openDetail(url) {
    opened = true
    editing = false
    showDetail(url)
  }

  function toggle() {
    if (opened) return close()
    opened = true
    refresh(false)
  }

  // KeyboardPanel calls owner.close() when it dismisses itself (outside click, focus loss);
  // without it the panel overwrites its `open` binding and the icon can no longer reopen it.
  function close() {
    opened = false
    editing = false
    detailUrl = ""
    detail = null
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: root.moduleName

    // Runs on whichever instance owns the target; open the panel on the focused screen instead.
    function showDetail(url: string): void {
      var focused = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name) : ""
      var target = root.peers().find(w => w.screenName() === focused) || root
      target.openDetail(url)
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try { root.config = Object.assign({ interval: 300, warnDays: 14, slowMs: 2000, targets: [] }, JSON.parse(text())) }
      catch (e) { console.warn("exeque.omarchy-http-uptime: invalid " + root.configPath + ": " + e) }
    }
    onFileChanged: reload()
  }

  FileView {
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var yellow = text().match(/^yellow\s*=\s*"([^"]+)"/m)
      var green = text().match(/^green\s*=\s*"([^"]+)"/m)
      if (yellow) root.warning = yellow[1]
      if (green) root.good = green[1]
    }
  }

  Process {
    id: detailProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (root.detailUrl) root.parseDetail(text)
    }
  }

  Process {
    id: checkProc
    environment: ({ UPTIME_KEEP: root.targets.map(t => t.url + "\t" + root.slowFor(t.url)).join("\n") })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parse(text)
    }
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (root.leader() === root) root.refresh(false)
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    dimmed: root.targets.length === 0
    active: root.worst > 0
    activeColor: root.severityColor(root.worst)
    tooltipText: root.opened ? "" : root.tooltipSummary()
    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh(true)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: root.editing ? urlField : null
    contentWidth: panel.fittedContentWidth(Style.space(root.editing ? 700 : 560))
    contentHeight: panel.fittedContentHeight(headerBlock.implicitHeight + panelColumn.spacing + panelColumn.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      anchors.fill: parent
      // The catcher sees keys before its children and swallows Enter, arrows, Space, Tab and h/j/k/l/x,
      // which breaks typing in the settings form; only the list and detail views use its navigation.
      blocked: root.editing
      onCloseRequested: root.close()

      // Header stays put; only the content below it scrolls.
      Column {
        id: headerBlock
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: panelColumn.spacing

        Item {
          width: parent.width
          height: Style.space(26)

          Row {
            anchors.left: parent.left
            anchors.right: headerActions.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            PanelActionButton {
              id: backButton
              visible: root.detailUrl !== ""
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf060"
              tooltipText: "Back"
              onClicked: { root.detailUrl = ""; root.detail = null }
            }

            Text {
              id: headingIcon
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.icon
              color: root.severityColor(root.worst)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - headingIcon.width - parent.spacing - (backButton.visible ? backButton.width + parent.spacing : 0)
              elide: Text.ElideMiddle
              textFormat: Text.PlainText
              text: root.editing ? "HTTP UPTIME · SETTINGS" : root.detailUrl ? root.detailUrl.replace(/^https?:\/\//, "") : "HTTP UPTIME"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            PanelActionButton {
              iconText: root.editing ? "\uf00c" : "\uf013"
              tooltipText: root.editing ? "Done" : "Settings"
              onClicked: {
                root.editing = !root.editing
                root.detailUrl = ""
                root.detail = null
              }
            }

            PanelActionButton {
              iconText: "\uf021"
              tooltipText: "Check all now"
              onClicked: root.refresh(true)
            }

            PanelActionButton {
              iconText: ""
              tooltipText: "Close (Esc)"
              onClicked: root.close()
            }
          }
        }

        PanelSeparator { width: parent.width }
      }

      Flickable {
        id: scroll
        anchors.top: headerBlock.bottom
        anchors.topMargin: panelColumn.spacing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: interactive ? Style.space(8) : 0
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: panelColumn
          width: scroll.width
          // Escape from a settings field bubbles up here while the key catcher is blocked.
          Keys.onEscapePressed: root.close()
          spacing: Style.space(10)


          Text {
            visible: root.targets.length === 0 && root.detailUrl === ""
            textFormat: Text.PlainText
            text: "No URLs monitored yet. Open settings to add one."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Item {
            visible: root.editing && root.targets.length > 0
            width: parent.width
            height: urlHeader.implicitHeight

            Text {
              id: urlHeader
              x: root.colGrip
              textFormat: Text.PlainText
              text: "URL"
              color: Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              anchors.right: parent.right
              spacing: root.colGap

              Repeater {
                model: ["Every (s)", "Slow (ms)", ""]

                Text {
                  required property string modelData
                  width: modelData ? root.colNumber : root.colAction
                  textFormat: Text.PlainText
                  text: modelData
                  color: Qt.darker(Color.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          Repeater {
            id: targetRepeater
            model: root.editing ? root.targets : root.displayTargets

            Column {
              id: row
              required property var modelData
              required property int index
              // Settings edits stay local until saved with ✓ (or Enter in the URL field).
              property string draftUrl: modelData.url
              property int draftInterval: root.intervalFor(modelData)
              property int draftSlow: root.slowFor(modelData.url)
              property bool invalid: false
              property bool confirmingDelete: false
              readonly property bool dirty: draftUrl.trim() !== modelData.url
                || draftInterval !== root.intervalFor(modelData) || draftSlow !== root.slowFor(modelData.url)

              function commit() {
                invalid = !root.commitTarget(modelData.url, draftUrl, draftInterval, draftSlow)
              }

              function revert() {
                draftUrl = modelData.url
                draftInterval = root.intervalFor(modelData)
                draftSlow = root.slowFor(modelData.url)
                invalid = false
                confirmingDelete = false
                urlInput.text = draftUrl
                // Typed text is only committed to `value` on Enter or blur, and SpinBox's displayText follows
                // the typed text, so format the value explicitly; otherwise the field keeps the typed text
                // and commits it later.
                resetSpin(intervalInput.field, draftInterval)
                resetSpin(slowInput.field, draftSlow)
              }

              // Setting the text breaks its binding to displayText, so restore it afterwards (displayText
              // has picked up the formatted text by then).
              function resetSpin(spin, value) {
                spin.value = value
                spin.contentItem.text = spin.textFromValue(value, spin.locale)
                spin.contentItem.text = Qt.binding(() => spin.displayText)
              }

              Connections {
                target: root
                function onEditingChanged() { if (!root.editing) row.revert() }
              }

              // NumberField reports typed values only once they are committed (Enter or blur); follow the
              // text as it is typed so the save button appears right away.
              function typed(spin) {
                var v = spin.valueFromText(spin.contentItem.text, spin.locale)
                return isNaN(v) ? null : Math.max(spin.from, Math.min(spin.to, v))
              }

              Connections {
                target: intervalInput.field.contentItem
                function onTextEdited() { var v = row.typed(intervalInput.field); if (v !== null) row.draftInterval = v }
              }

              Connections {
                target: slowInput.field.contentItem
                function onTextEdited() { var v = row.typed(slowInput.field); if (v !== null) row.draftSlow = v }
              }
              readonly property var result: root.results[modelData.url]
              visible: root.detailUrl === ""
              width: panelColumn.width
              spacing: Style.space(4)
              opacity: root.dragFrom === index ? 0.4 : 1

              // Divides URLs needing attention from healthy ones.
              PanelSeparator {
                visible: !root.editing && root.sectionStart(row.index)
                width: parent.width
              }

              Item {
                width: parent.width
                height: Math.max(Style.space(38), controls.implicitHeight)

                // Drop indicators: above this row, and below the last row.
                Rectangle {
                  visible: root.dragFrom >= 0 && root.dragTo === row.index && root.dragTo !== root.dragFrom && root.dragTo !== root.dragFrom + 1
                  y: -panelColumn.spacing / 2 - height / 2
                  width: parent.width
                  height: Style.space(2)
                  color: Color.accent
                }

                Text {
                  id: grip
                  visible: root.editing
                  width: root.colGrip
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "\uf0c9"
                  color: gripArea.containsMouse || root.dragFrom === row.index ? Color.foreground : Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body

                  MouseArea {
                    id: gripArea
                    anchors.fill: parent
                    anchors.margins: -Style.space(6)
                    hoverEnabled: true
                    preventStealing: true
                    cursorShape: root.dragFrom >= 0 ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    onPressed: { root.dragFrom = row.index; root.dragTo = row.index }
                    onPositionChanged: function(mouse) {
                      if (root.dragFrom >= 0) root.dragTo = root.dropIndex(mapToItem(panelColumn, mouse.x, mouse.y).y)
                    }
                    onReleased: {
                      root.moveTarget(root.dragFrom, root.dragTo)
                      root.dragFrom = -1
                      root.dragTo = -1
                    }
                    onCanceled: { root.dragFrom = -1; root.dragTo = -1 }
                  }
                }

                Rectangle {
                  id: dot
                  visible: !root.editing
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(8)
                  height: width
                  radius: width / 2
                  color: root.dotColor(row.result)
                }

                Column {
                  id: info
                  anchors.left: root.editing ? grip.right : dot.right
                  anchors.leftMargin: root.editing ? 0 : Style.space(10)
                  anchors.right: controls.visible ? controls.left : parent.right
                  anchors.rightMargin: root.editing ? root.colGap : Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    visible: root.editing && row.confirmingDelete
                    width: parent.width
                    height: urlInput.implicitHeight
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideMiddle
                    textFormat: Text.PlainText
                    text: "Delete " + row.modelData.url.replace(/^https?:\/\//, "") + " and its history?"
                    color: root.bar ? root.bar.urgent : Color.urgent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }

                  TextField {
                    id: urlInput
                    visible: root.editing && !row.confirmingDelete
                    width: parent.width
                    text: row.modelData.url
                    foreground: row.invalid ? (root.bar ? root.bar.urgent : Color.urgent) : Color.foreground
                    onTextEdited: { row.draftUrl = text; row.invalid = false }
                    onAccepted: if (row.dirty) row.commit()
                  }

                  Text {
                    visible: !root.editing
                    width: parent.width
                    elide: Text.ElideMiddle
                    textFormat: Text.PlainText
                    text: row.modelData.url
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.underline: openArea.containsMouse
                  }

                  Text {
                    visible: !root.editing
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: root.summary(row.result)
                    color: root.statusColor(row.result)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  id: openArea
                  anchors.fill: info
                  enabled: !root.editing
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.showDetail(row.modelData.url)
                }

                Row {
                  id: controls
                  visible: root.editing
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: root.colGap

                  NumberField {
                    id: intervalInput
                    visible: !row.confirmingDelete
                    anchors.verticalCenter: parent.verticalCenter
                    fieldWidth: root.colNumber
                    from: 10
                    to: 86400
                    stepSize: 30
                    value: root.intervalFor(row.modelData)
                    onModified: function(v) { row.draftInterval = v }
                  }

                  NumberField {
                    id: slowInput
                    visible: !row.confirmingDelete
                    anchors.verticalCenter: parent.verticalCenter
                    fieldWidth: root.colNumber
                    from: 1
                    to: 60000
                    stepSize: 100
                    value: root.slowFor(row.modelData.url)
                    onModified: function(v) { row.draftSlow = v }
                  }

                  // Trash when the row is clean; save and revert while it has unsaved edits.
                  Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.colAction
                    height: trashButton.height

                    // Entries with history ask first; deleting removes up to 30 days of data.
                    PanelActionButton {
                      id: trashButton
                      visible: !row.dirty && !row.confirmingDelete
                      anchors.centerIn: parent
                      iconText: "\uf1f8"
                      tooltipText: "Stop monitoring"
                      onClicked: {
                        if (root.uptime[row.modelData.url]) row.confirmingDelete = true
                        else root.removeTarget(row.modelData.url)
                      }
                    }

                    Row {
                      visible: row.confirmingDelete
                      anchors.centerIn: parent
                      spacing: Style.space(2)

                      PanelActionButton {
                        iconText: "\uf1f8"
                        foreground: root.bar ? root.bar.urgent : Color.urgent
                        hoverColor: foreground
                        tooltipText: "Delete entry and history"
                        onClicked: root.removeTarget(row.modelData.url)
                      }

                      PanelActionButton {
                        iconText: "\uf00d"
                        tooltipText: "Cancel"
                        onClicked: row.confirmingDelete = false
                      }
                    }

                    Row {
                      visible: row.dirty
                      anchors.centerIn: parent
                      spacing: Style.space(2)

                      PanelActionButton {
                        iconText: "\uf00c"
                        tooltipText: row.invalid ? "Invalid or duplicate URL" : "Save"
                        onClicked: row.commit()
                      }

                      PanelActionButton {
                        iconText: "\uf0e2"
                        tooltipText: "Revert"
                        onClicked: row.revert()
                      }
                    }
                  }
                }
              }

              Rectangle {
                visible: root.dragFrom >= 0 && row.index === root.targets.length - 1 && root.dragTo === root.targets.length && root.dragFrom !== row.index
                width: parent.width
                height: Style.space(2)
                color: Color.accent
              }

              Text {
                visible: !root.editing && !!root.uptime[row.modelData.url]
                x: Style.space(18)
                textFormat: Text.PlainText
                text: root.windows.map(w => w.label + " " + root.pctText((root.uptime[row.modelData.url] || {})[w.key])).join("   ")
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          // Detail view for one URL: current status, uptime charts, last 10 checks.
          Column {
            id: detailView
            readonly property var result: root.results[root.detailUrl]
            visible: root.detailUrl !== "" && !root.editing
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              height: openButton.height

              Rectangle {
                id: detailDot
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(8)
                height: width
                radius: width / 2
                color: root.dotColor(detailView.result)
              }

              Text {
                anchors.left: detailDot.right
                anchors.leftMargin: Style.space(10)
                anchors.right: openButton.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.summary(detailView.result)
                color: root.statusColor(detailView.result)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Button {
                id: openButton
                anchors.right: parent.right
                text: "Open in browser"
                bordered: true
                onClicked: root.openUrl(root.detailUrl)
              }
            }

            PanelSeparator { width: parent.width }

            PanelSectionHeader { text: "UPTIME" }

            Repeater {
              model: root.windows

              Column {
                required property var modelData
                width: detailView.width
                spacing: Style.space(4)

                Item {
                  width: parent.width
                  height: windowLabel.implicitHeight

                  Text {
                    id: windowLabel
                    textFormat: Text.PlainText
                    text: modelData.label + "  " + root.pctText((root.uptime[root.detailUrl] || {})[modelData.key])
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  // Legend
                  Text {
                    anchors.right: parent.right
                    textFormat: Text.StyledText
                    text: "<font color=\"" + Color.foreground + "\">━</font> uptime   <font color=\"" + root.warning + "\">━</font> slow"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                UptimeChart {
                  width: parent.width
                  buckets: root.detail && root.detail.series[modelData.key] ? root.detail.series[modelData.key] : []
                  slowBuckets: root.detail && root.detail.slow[modelData.key] ? root.detail.slow[modelData.key] : []
                  slowColor: root.warning
                  bucketSeconds: modelData.size
                  urgent: root.bar ? root.bar.urgent : Color.urgent
                }
              }
            }

            PanelSeparator { width: parent.width }

            PanelSectionHeader { text: "LAST 10 CHECKS" }

            Text {
              visible: !!root.detail && root.detail.checks.length === 0
              textFormat: Text.PlainText
              text: "No checks recorded yet."
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: root.detail ? root.detail.checks : []

              Item {
                required property var modelData
                readonly property color tone: root.severityColor(root.severity(modelData.status))
                width: detailView.width
                height: Style.space(20)

                Text {
                  id: checkTime
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(110)
                  textFormat: Text.PlainText
                  text: root.timeText(modelData.time)
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Rectangle {
                  id: checkDot
                  anchors.left: checkTime.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(6)
                  height: width
                  radius: width / 2
                  color: root.severity(modelData.status) === 0 ? root.good : parent.tone
                }

                Text {
                  anchors.left: checkDot.right
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(90)
                  textFormat: Text.PlainText
                  text: root.statusLabel(modelData.status)
                  color: parent.tone
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.right: checkMs.left
                  anchors.rightMargin: Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: modelData.code === "" || modelData.code === "000" ? "–" : "HTTP " + modelData.code
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  id: checkMs
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(70)
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: modelData.ms === null ? "–" : modelData.ms + " ms"
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          PanelSeparator { visible: root.editing; width: parent.width }

          Item {
            visible: root.editing
            width: parent.width
            height: Math.max(urlField.implicitHeight, addControls.implicitHeight)

            TextField {
              id: urlField
              anchors.left: parent.left
              anchors.leftMargin: root.colGrip
              anchors.right: addControls.left
              anchors.rightMargin: root.colGap
              anchors.verticalCenter: parent.verticalCenter
              placeholderText: "https://example.com/health"
              onAccepted: addButton.clicked()
            }

            Row {
              id: addControls
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: root.colGap

              // NumberField only reports edits through modified(); its `value` keeps the initial binding,
              // so the add button reads the spin box (`field.value`) directly.
              NumberField {
                id: addInterval
                anchors.verticalCenter: parent.verticalCenter
                fieldWidth: root.colNumber
                from: 10
                to: 86400
                stepSize: 30
                value: root.config.interval
              }

              NumberField {
                id: addSlow
                anchors.verticalCenter: parent.verticalCenter
                fieldWidth: root.colNumber
                from: 1
                to: 60000
                stepSize: 100
                value: root.config.slowMs
              }

              Button {
                id: addButton
                anchors.verticalCenter: parent.verticalCenter
                width: root.colAction
                text: "Add"
                bordered: true
                onClicked: if (root.addTarget(urlField.text, addInterval.field.value, addSlow.field.value)) urlField.text = ""
              }
            }
          }

          PanelSeparator { visible: root.editing; width: parent.width }

          PanelSectionHeader { visible: root.editing; text: "DEFAULTS & ALERTS" }

          Flow {
            visible: root.editing
            width: parent.width
            spacing: Style.space(14)

            NumberField {
              label: "Default interval (s)"
              from: 10
              to: 86400
              stepSize: 30
              value: root.config.interval
              onModified: function(v) { root.save({ interval: v }) }
            }

            NumberField {
              label: "Slow above (ms)"
              from: 1
              to: 60000
              stepSize: 100
              value: root.config.slowMs
              onModified: function(v) { root.save({ slowMs: v }); root.recheck(root.targets.map(t => t.url)) }
            }

            NumberField {
              label: "Cert warning (days)"
              from: 1
              to: 365
              value: root.config.warnDays
              onModified: function(v) { root.save({ warnDays: v }); root.recheck(root.targets.map(t => t.url)) }
            }
          }
        }
      }

      // Scroll indicator, shown only when the content overflows.
      Rectangle {
        visible: scroll.interactive
        anchors.right: parent.right
        y: scroll.y + scroll.visibleArea.yPosition * scroll.height
        width: Style.space(3)
        height: scroll.visibleArea.heightRatio * scroll.height
        radius: width / 2
        color: Color.muted
        opacity: scroll.moving ? 0.9 : 0.5
      }
    }
  }
}
