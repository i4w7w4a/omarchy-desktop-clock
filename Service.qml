pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons as Commons

Scope {
  id: root

  property var shell: null
  readonly property Settings settings: Settings { shell: root.shell }
  readonly property var config: settings.saved
  property var cursor: null
  property var ipcStats: null
  property bool helperReady: false
  property bool timeZoneAvailable: true
  property string displayTime: Qt.formatTime(new Date(), "HH:mm")
  property string sentConfig: ""
  property bool helperWarning: false
  readonly property bool running: settings.entry !== null && Array.from(surfaces.instances).some(surface => surface.visible)
  readonly property int cursorHz: Array.from(surfaces.instances).some(surface => surface.needsPointer) ? config.cursorHz : 0
  readonly property bool cursorAvailable: helperReady && (cursorHz === 0 || cursor !== null)
  readonly property bool sharedShineWanted: config.shineSync && Array.from(surfaces.instances).some(surface => surface.canShine)
  signal timeUpdated(string text, bool animate)
  signal sharedShine()

  function barHeightFor(name) {
    const bar = shell ? shell.bar : null
    if (bar && bar.position === "top" && typeof bar.barSizeFor === "function")
      return Math.max(0, Math.round(bar.barSizeFor(name)))
    return 0
  }

  function updateTime(text, animate) {
    const changed = text !== displayTime
    displayTime = text
    if (changed || !animate) timeUpdated(text, changed && animate)
  }

  function publishConfig() {
    if (!helper.running || !helperReady) return
    const next = JSON.stringify({ hz: cursorHz, inputIdle: inputIdle.isIdle, zone: config.timeZone })
    if (sentConfig === next) return
    sentConfig = next
    if (!cursorHz) {
      cursor = null
      ipcStats = null
    }
    helper.write(next + "\n")
  }

  function receive(line) {
    if (line.length > 4096) return
    let message
    try { message = JSON.parse(line) } catch (_) { return }
    if (!message || typeof message !== "object") return
    if (message.ready === true) {
      helperReady = true
      helperWarning = false
      publishConfig()
    }
    if (typeof message.time === "string" && /^\d{2}:\d{2}$/.test(message.time)) {
      timeZoneAvailable = message.zoneAvailable === true
      updateTime(message.time, message.animate === true)
    }
    if (message.cursor === null) cursor = null
    else if (cursorHz && Array.isArray(message.cursor) && message.cursor.length === 2
        && message.cursor.every(value => Number.isFinite(value) && Math.abs(value) < 1000000)) {
      cursor = { x: message.cursor[0], y: message.cursor[1] }
    }
    if (cursorHz && message.ipc && Number.isFinite(message.ipc.p95Ms)) ipcStats = message.ipc
  }

  function scheduleSharedShine() {
    sharedTimer.stop()
    if (!sharedShineWanted) return
    sharedTimer.interval = Math.round(1000 * (config.shinePeriodSec
      + (Math.random() * 2 - 1) * config.shineJitterSec))
    sharedTimer.start()
  }

  function status() {
    return JSON.stringify({
      time: displayTime, timeZoneAvailable, language: settings.language, helperReady,
      helperPid: helper.running ? helper.processId : 0, cursorAvailable, cursorHz,
      inputIdle: inputIdle.isIdle, ipc: ipcStats,
      outputs: Array.from(surfaces.instances).map(surface => ({
        name: surface.outputName, visible: surface.visible,
        reducedMotion: surface.reduced, inkX: surface.inkX, inkY: surface.inkY,
        inkWidth: surface.inkWidth, inkHeight: surface.inkHeight,
        size: surface.options.size, gap: surface.options.gap, visibleGap: surface.visibleGap,
        width: surface.implicitWidth, height: surface.implicitHeight, motion: surface.motionStatus()
      }))
    })
  }

  onRunningChanged: {
    if (running) helper.running = true
    else {
      restart.stop()
      helper.running = false
    }
  }
  onCursorHzChanged: Qt.callLater(publishConfig)
  onConfigChanged: {
    Qt.callLater(publishConfig)
    if (sharedTimer.running && (sharedTimer.period !== config.shinePeriodSec
        || sharedTimer.jitter !== config.shineJitterSec)) scheduleSharedShine()
  }
  onSharedShineWantedChanged: scheduleSharedShine()
  Component.onCompleted: if (running) helper.running = true

  IdleMonitor {
    id: inputIdle
    enabled: root.cursorHz > 0
    timeout: 0.5
    respectInhibitors: false
    onIsIdleChanged: root.publishConfig()
  }

  Timer {
    id: sharedTimer
    property int period: 0
    property int jitter: 0
    onRunningChanged: if (running) {
      period = root.config.shinePeriodSec
      jitter = root.config.shineJitterSec
    }
    onTriggered: {
      root.sharedShine()
      root.scheduleSharedShine()
    }
  }

  Timer {
    id: restart
    interval: 1500
    onTriggered: if (root.running && !helper.running) helper.running = true
  }

  // Hyprland 0.56 does not emit an IPC event for every DPMS change.
  Timer {
    interval: 2000
    repeat: true
    running: root.settings.entry !== null && root.config.showClock
      && Quickshell.screens.some(screen => root.settings.effectiveForOutput(screen.name, root.config).enabled)
    onTriggered: Hyprland.refreshMonitors()
  }

  // Maintain a readable local clock even if the optional session process fails.
  Timer {
    running: root.running && !root.helperReady
    interval: 1000
    repeat: true
    onTriggered: root.updateTime(Qt.formatTime(new Date(), "HH:mm"), false)
  }

  Process {
    id: helper
    command: ["python3", "-B", "-u", decodeURIComponent(String(Qt.resolvedUrl("session.py")).replace(/^file:\/\//, ""))]
    stdinEnabled: true
    stdout: SplitParser { onRead: line => root.receive(line) }
    stderr: SplitParser {
      onRead: line => {
        if (!root.helperWarning) console.warn("Desktop Clock session:", line.slice(0, 300))
        root.helperWarning = true
      }
    }
    onRunningChanged: if (!running) {
      root.helperReady = false
      root.cursor = null
      root.ipcStats = null
      root.sentConfig = ""
      if (root.running) restart.restart()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      // Refresh the monitor state immediately on hotplug and configuration reload.
      if (event.name === "monitoradded" || event.name === "monitorremoved" || event.name === "configreloaded")
        Hyprland.refreshMonitors()
    }
  }

  Variants {
    id: surfaces
    model: Quickshell.screens

    ClockSurface {
      id: surface
      required property var modelData
      readonly property var monitor: modelData ? Hyprland.monitorFor(modelData) : null
      screen: modelData
      owner: root
      outputName: modelData ? modelData.name : ""
      barHeight: root.barHeightFor(outputName)
      options: root.settings.effectiveForOutput(outputName, root.config)
      powered: root.settings.entry !== null && !!modelData && modelData.width > 0 && modelData.height > 0
        && (!monitor || monitor.lastIpcObject.dpmsStatus !== false)
    }
  }

  Commons.ShellIpc {
    target: "minuteInk"
    function status(): string { return root.status() }
  }
}
