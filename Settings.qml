pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons

QtObject {
  id: root

  readonly property string pluginId: "io.github.i4w7w4a.desktop-clock"
  property var shell: null
  property var entry: null
  property var pending: null
  property string queuedLanguage: ""
  property bool saveFailed: false
  readonly property bool saving: pending !== null
  readonly property bool canWrite: entry !== null && !!shell
    && typeof shell.updateEntryInline === "function"
  readonly property var saved: normalize(entry)
  readonly property string language: queuedLanguage || (pending && pending.language) || saved.language

  readonly property var choices: ({
    monitorMode: ["all", "selected"],
    readability: ["standard", "high"],
    reducedMotion: ["system", "always"],
    minuteEffect: ["slice", "roll", "dissolve", "none", "original"]
  })
  // Minimum, maximum, and step in display units.
  readonly property var limits: ({
    size: [48, 144, 1], gap: [0, 240, 1], centerOffset: [-25, 25, 1],
    fontWeight: [400, 700, 100], inkOpacity: [70, 100, 1],
    outlineWidth: [0, 2, 0.25], outlineOpacity: [0, 100, 1],
    shadowOpacity: [0, 60, 1], shadowBlur: [0, 16, 1], shadowOffset: [0, 6, 1],
    backingOpacity: [40, 90, 1],
    shinePeriodSec: [8, 120, 1], shineJitterSec: [0, 5, 1],
    shineDurationMs: [600, 1800, 10], shineStrength: [0, 60, 1],
    shineWidth: [12, 45, 1], shineAngle: [0, 30, 1],
    hoverScale: [0, 10, 1], hoverInMs: [80, 350, 1], hoverOutMs: [60, 250, 1],
    hoverLight: [0, 80, 1], hoverFollowMs: [0, 160, 1],
    hoverRadius: [0.5, 1.5, 0.1], hoverEnterPadding: [0, 16, 1], hoverExitPadding: [0, 12, 1],
    colorSpread: [0, 8, 0.5], sliceShift: [0, 8, 1], slicePulses: [1, 2, 1],
    secondPulseStrength: [25, 75, 1], distortionMs: [80, 120, 1],
    tailMs: [120, 300, 1], rollMs: [160, 280, 1], cursorHz: [15, 60, 1]
  })
  readonly property var defaults: ({
    language: Commons.I18n.language === "ru" ? "ru" : "en",
    showClock: true, monitorMode: "all", outputs: {}, size: 80, gap: 12, centerOffset: 0,
    readability: "standard",
    reducedMotion: "system", timeZone: "system",
    fontFamily: "Inter", fontWeight: 500, inkOpacity: 98, inkColor: "#d7ddd4",
    outlineWidth: 1, outlineOpacity: 65, shadowOpacity: 35, shadowBlur: 8, shadowOffset: 2,
    backing: false, backingOpacity: 72,
    shineEnabled: true, shinePeriodSec: 17, shineJitterSec: 3, shineDurationMs: 1100,
    shineStrength: 18, shineWidth: 22, shineAngle: 12, shineSync: false,
    hoverEnabled: true, hoverScale: 6, hoverInMs: 190, hoverOutMs: 145, hoverLight: 45,
    hoverFollowMs: 80, hoverRadius: 0.8, hoverEnterPadding: 6, hoverExitPadding: 4,
    minuteEffect: "slice", colorSpread: 2, sliceShift: 2, slicePulses: 2, secondPulseStrength: 50,
    distortionMs: 120, tailMs: 250, fragmentShuffle: false, rollMs: 240, cursorHz: 30
  })
  function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value)
  }

  function outputNameValid(name) {
    return typeof name === "string" && /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$/.test(name)
      && name !== "constructor" && name !== "prototype"
  }

  function numberFor(key, value, fallback) {
    if (typeof value !== "number" || !Number.isFinite(value)) return fallback
    const range = limits[key]
    const result = Math.max(range[0], Math.min(range[1], Math.round(value / range[2]) * range[2]))
    return Number(result.toFixed(3))
  }

  function validFontFamily(value) {
    return typeof value === "string" && /^[^<>\x00-\x1f\x7f]{1,96}$/.test(value)
  }

  function normalize(config) {
    const source = isObject(config) ? config : {}
    const result = Object.assign({}, defaults)
    for (const key of Object.keys(limits)) result[key] = numberFor(key, source[key], defaults[key])
    for (const key of Object.keys(choices))
      if (choices[key].includes(source[key])) result[key] = source[key]
    for (const key of Object.keys(defaults))
      if (typeof defaults[key] === "boolean" && typeof source[key] === "boolean") result[key] = source[key]

    if (source.language === "ru" || source.language === "en") result.language = source.language
    if (validFontFamily(source.fontFamily)) result.fontFamily = source.fontFamily
    if (typeof source.inkColor === "string" && /^#[0-9a-fA-F]{6}$/.test(source.inkColor))
      result.inkColor = source.inkColor.toLowerCase()
    if (typeof source.timeZone === "string"
        && /^[A-Za-z][A-Za-z0-9_+-]*(?:\/[A-Za-z0-9_+-]+)*$/.test(source.timeZone)
        && source.timeZone.length <= 96) result.timeZone = source.timeZone
    result.shineJitterSec = Math.min(result.shineJitterSec, Math.floor(result.shinePeriodSec / 3))

    result.outputs = {}
    if (isObject(source.outputs)) {
      for (const name of Object.keys(source.outputs).filter(outputNameValid).sort().slice(0, 64)) {
        const input = source.outputs[name]
        if (!isObject(input)) continue
        const output = {}
        if (typeof input.enabled === "boolean") output.enabled = input.enabled
        for (const key of ["size", "gap"])
          if (typeof input[key] === "number" && Number.isFinite(input[key]))
            output[key] = numberFor(key, input[key], defaults[key])
        if (Object.keys(output).length) result.outputs[name] = output
      }
    }
    return result
  }

  function effectiveForOutput(name, config) {
    const common = config || saved
    const override = Object.prototype.hasOwnProperty.call(common.outputs, name) ? common.outputs[name] : {}
    const enabled = typeof override.enabled === "boolean" ? override.enabled : common.monitorMode === "all"
    return Object.assign({}, common, override, { enabled: common.showClock && enabled })
  }

  function setFontFamily(family) {
    if (!validFontFamily(family)) return false
    return write({ fontFamily: family })
  }

  function setLanguage(code) {
    if (!canWrite || (code !== "en" && code !== "ru") || language === code) return
    queuedLanguage = code
    if (!saving) flushLanguage()
  }

  function flushLanguage() {
    if (saving || !queuedLanguage) return
    const code = queuedLanguage
    queuedLanguage = ""
    write({ language: code })
  }

  function write(values) {
    if (!canWrite || saving) return false
    saveFailed = false
    if (Object.keys(values).every(key => entry[key] === values[key])) return true
    // Keep the stored appearance and per-output values verbatim when editing a panel field.
    const replacement = Object.assign({}, entry, values)
    delete replacement.id
    pending = values
    confirmation.restart()
    try {
      if (!shell.updateEntryInline(pluginId, replacement)) failSave()
    } catch (_) {
      failSave()
    }
    return !saveFailed
  }

  function load(raw) {
    try {
      const config = JSON.parse(raw)
      entry = config && config.version === 1 && Array.isArray(config.plugins)
        ? config.plugins.find(value => value && value.id === pluginId) || null : null
    } catch (_) {
      entry = null
    }
    if (entry && pending && Object.keys(pending).every(key => entry[key] === pending[key])) {
      confirmation.stop()
      pending = null
      Qt.callLater(flushLanguage)
    }
  }

  function failSave() {
    confirmation.stop()
    pending = null
    queuedLanguage = ""
    saveFailed = true
  }

  property Timer confirmation: Timer {
    interval: 2400
    onTriggered: root.failSave()
  }

  property FileView configFile: FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.load(text())
    onLoadFailed: root.entry = null
    onFileChanged: Qt.callLater(root.configFile.reload)
  }
}
