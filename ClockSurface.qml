pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons as Commons

PanelWindow {
  id: root

  required property var options
  required property var owner
  required property string outputName
  required property int barHeight
  required property bool powered
  readonly property bool reduced: Commons.Style.reduceMotion || options.reducedMotion === "always"
  readonly property bool needsPointer: visible && options.hoverEnabled
    && (options.hoverLight > 0 || (!reduced && options.hoverScale > 0))
  readonly property bool canShine: visible && !reduced && options.shineEnabled && options.shineStrength > 0
  readonly property bool needsLocalShine: canShine && !options.shineSync
  readonly property real inkWidth: face.inkRect.width
  readonly property real inkHeight: face.inkRect.height
  readonly property int visibleGap: top + Math.round(face.inkRect.y) - barHeight
  readonly property real inkX: screen ? screen.x + left + face.inkRect.x : 0
  readonly property real inkY: screen ? screen.y + top + face.inkRect.y : 0
  readonly property int left: screen ? Math.round(Math.max(0, Math.min(screen.width - implicitWidth,
    screen.width * (0.5 + options.centerOffset / 100) - face.inkRect.x - face.inkRect.width / 2))) : 0
  readonly property int top: screen ? Math.round(Math.min(screen.height - implicitHeight,
    barHeight + options.gap - face.inkRect.y)) : 0

  visible: powered && options.enabled
  implicitWidth: Math.ceil(face.implicitWidth)
  implicitHeight: Math.ceil(face.implicitHeight)
  color: "transparent"
  surfaceFormat.opaque: false
  anchors.top: true
  anchors.left: true
  margins.top: top
  margins.left: left
  exclusionMode: ExclusionMode.Ignore
  mask: Region {}
  WlrLayershell.layer: WlrLayer.Bottom
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  WlrLayershell.namespace: "i4w7w4a-desktop-clock"

  function updatePointer() {
    const point = owner.cursor
    face.setPointer(point && screen ? point.x - screen.x - left : 0,
                    point && screen ? point.y - screen.y - top : 0,
                    needsPointer && !!point && !!screen)
  }

  function showTime(text, animate) { face.setTime(text, animate && visible) }
  function shine() { if (canShine) face.startShine() }
  function motionStatus() {
    return { hovered: face.hovered, scale: face.visualScale, time: face.displayTime, shader: face.shaderAvailable,
      minute: face.minuteActive, minuteMs: face.minuteElapsed, shine: face.shineActive }
  }

  function scheduleShine(initial) {
    localShine.stop()
    if (needsLocalShine) {
      const period = options.shinePeriodSec * 1000
      const jitter = options.shineJitterSec * 1000
      let seed = 0
      for (let index = 0; index < outputName.length; index++)
        seed = ((seed * 31 + outputName.charCodeAt(index)) >>> 0)
      const phase = ((Math.imul(seed, 2654435761) >>> 0) % 1000) / 1000
      localShine.interval = initial ? Math.round(period * (0.25 + phase * 0.75))
        : Math.round(period + (Math.random() * 2 - 1) * jitter)
      localShine.start()
    }
  }

  onNeedsPointerChanged: Qt.callLater(updatePointer)
  onLeftChanged: Qt.callLater(updatePointer)
  onTopChanged: Qt.callLater(updatePointer)
  onNeedsLocalShineChanged: scheduleShine(true)
  onOptionsChanged: {
    Qt.callLater(updatePointer)
    if (localShine.running && (localShine.period !== options.shinePeriodSec
        || localShine.jitter !== options.shineJitterSec)) scheduleShine(true)
  }
  Component.onCompleted: {
    showTime(owner.displayTime, false)
    scheduleShine(true)
    Qt.callLater(updatePointer)
  }

  Timer {
    id: localShine
    property int period: 0
    property int jitter: 0
    onRunningChanged: if (running) {
      period = root.options.shinePeriodSec
      jitter = root.options.shineJitterSec
    }
    onTriggered: {
      root.shine()
      root.scheduleShine(false)
    }
  }

  ClockFace {
    id: face
    width: root.implicitWidth
    height: root.implicitHeight
    options: root.options
    reducedMotion: root.reduced
    effectsActive: root.visible
  }

  Connections {
    target: root.owner
    function onCursorChanged() { root.updatePointer() }
    function onTimeUpdated(text, animate) { root.showTime(text, animate) }
    function onSharedShine() { if (root.options.shineSync) root.shine() }
  }

  Connections {
    target: root.screen
    function onGeometryChanged() { Qt.callLater(root.updatePointer) }
  }
}
