pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import qs.Commons as Commons

Item {
  id: root

  required property var options
  property bool reducedMotion: Commons.Style.reduceMotion
  property bool effectsActive: true

  readonly property string displayTime: state.time
  readonly property bool hovered: state.hovered
  readonly property real visualScale: state.magnification
  readonly property bool minuteActive: state.previousTime !== state.time && minuteElapsed < minuteDuration
  readonly property real minuteElapsed: state.minuteElapsed
  readonly property real minuteDuration: {
    if (options.minuteEffect === "roll") return options.rollMs
    if (options.minuteEffect === "dissolve") return 160
    if (options.minuteEffect === "slice" || options.minuteEffect === "original")
      return Math.max(options.distortionMs, options.tailMs, options.minuteEffect === "original" ? 121 : 0)
    return 0
  }
  readonly property bool shineActive: shineTravel.running
  // The union of all possible glyphs makes the gap and hover box independent of the displayed time.
  readonly property rect inkRect: Qt.rect((width - inkWidth) / 2,
    (height - inkHeight) / 2, inkWidth, inkHeight)

  readonly property bool motionEnabled: effectsActive && visible && !reducedMotion && !Commons.Style.reduceMotion
  readonly property bool shaderSupported: GraphicsInfo.api !== GraphicsInfo.Software && GraphicsInfo.api !== GraphicsInfo.Null
  readonly property bool shaderAvailable: shaderSupported && clockShader.status !== ShaderEffect.Error
  readonly property color inkColor: options.inkColor
  readonly property real contour: options.readability === "high" ? Math.max(1.5, options.outlineWidth) : options.outlineWidth
  readonly property bool backed: options.backing || options.readability === "high"
  readonly property font faceFont: Qt.font({
    family: inter.item && inter.item.status === FontLoader.Ready ? inter.item.name : options.fontFamily,
    pixelSize: options.size,
    weight: options.fontWeight,
    variableAxes: options.fontFamily === "Inter" ? { wght: options.fontWeight, opsz: 14 } : {},
    features: { tnum: 1 },
    kerning: false,
    hintingPreference: Font.PreferNoHinting
  })

  readonly property var metrics: [zero, one, two, three, four, five, six, seven, eight, nine, colon].map(metric => ({
    advance: metric.advanceWidth, bounds: metric.tightBoundingRect
  }))
  readonly property real digitWidth: Math.ceil(Math.max(1, ...metrics.slice(0, 10).map(metric =>
    Math.max(metric.advance, metric.bounds.width))))
  readonly property real colonWidth: Math.ceil(Math.max(1, metrics[10].advance, metrics[10].bounds.width))
  readonly property real advanceWidth: 4 * digitWidth + colonWidth
  readonly property real inkTop: Math.floor(Math.min(...metrics.map(metric => metric.bounds.y)))
  readonly property real inkBottom: Math.ceil(Math.max(...metrics.map(metric => metric.bounds.y + metric.bounds.height)))
  readonly property real inkWidth: advanceWidth - digitWidth + Math.max(...metrics.slice(0, 10).map(metric => metric.bounds.width))
  readonly property real inkHeight: Math.max(1, inkBottom - inkTop)
  readonly property real shadowPadding: options.shadowOpacity > 0 ? 1.75 * options.shadowBlur + options.shadowOffset : 0
  readonly property int pad: Math.ceil(Math.max(7, shadowPadding, backed ? 12 : 0,
    options.sliceShift + options.colorSpread / 2, contour) + 2)
  readonly property int maskWidth: advanceWidth + 2 * pad
  readonly property int maskHeight: inkHeight + 2 * pad
  readonly property real maxScale: 1 + (options.hoverEnabled ? options.hoverScale / 100 : 0)

  readonly property bool original: minuteActive && options.minuteEffect === "original"
  readonly property string drawnTime: original && minuteElapsed < 121
    ? (minuteElapsed < 44 ? state.previousTime : shuffledTime(minuteElapsed < 81 ? 2 : 5)) : state.time
  readonly property bool hasFragments: minuteActive && options.minuteEffect === "slice" && options.fragmentShuffle
    && minuteElapsed < 80
  readonly property string secondaryTime: hasFragments ? shuffledTime(minuteElapsed < 40 ? 2 : 5) : state.previousTime
  readonly property vector4d changedDigits: Qt.vector4d(state.previousTime[0] !== state.time[0] ? 1 : 0,
    state.previousTime[1] !== state.time[1] ? 1 : 0, state.previousTime[3] !== state.time[3] ? 1 : 0,
    state.previousTime[4] !== state.time[4] ? 1 : 0)
  readonly property real sliceProgress: minuteElapsed / options.distortionMs
  readonly property bool secondPulse: sliceProgress >= 65 / 120
  readonly property real pulse: {
    if (!minuteActive || (options.minuteEffect !== "slice" && !original)
        || (options.sliceShift === 0 && options.colorSpread === 0 && !hasFragments)) return 0
    if (sliceProgress < 35 / 120) return Math.pow(1 - sliceProgress * 120 / 35, 2)
    if (!secondPulse || options.slicePulses < 2 || sliceProgress >= 1) return 0
    const decay = Math.min(1, (sliceProgress - 65 / 120) * 120 / 55)
    return options.secondPulseStrength / 100 * Math.pow(1 - decay, 2)
  }
  readonly property real tail: {
    if (!minuteActive || (options.minuteEffect !== "slice" && !original)
        || options.tailMs <= options.distortionMs) return 0
    const decay = Math.max(0, (minuteElapsed - options.distortionMs) / (options.tailMs - options.distortionMs))
    return 0.075 * Math.pow(Math.max(0, 1 - decay), 3)
  }

  implicitWidth: Math.ceil(maskWidth * maxScale) + 2
  implicitHeight: Math.ceil(maskHeight * maxScale) + 2
  LayoutMirroring.enabled: false
  LayoutMirroring.childrenInherit: true

  function validTime(text: string): bool {
    return /^(?:[01][0-9]|2[0-3]):[0-5][0-9]$/.test(text)
  }

  function setTime(text: string, animate: bool): void {
    if (!validTime(text) || (animate && text === state.time)) return
    if (animate && state.initialized && motionEnabled) {
      playMinute(text)
    } else {
      state.time = text
      state.initialized = true
      settleMinute()
    }
  }

  function playMinute(text: string): void {
    minuteMotion.stop()
    state.previousTime = state.time
    state.time = text
    state.minuteElapsed = 0
    if (minuteActive) {
      minuteMotion.from = 0
      minuteMotion.to = minuteDuration
      minuteMotion.duration = scaledDuration(minuteDuration)
      minuteMotion.start()
    }
  }

  function settleMinute(): void {
    minuteMotion.stop()
    state.previousTime = state.time
    state.minuteElapsed = minuteDuration
  }

  function shuffledTime(offset: int): string {
    let result = ""
    for (let index = 0; index < 5; index++) {
      const char = state.time[index]
      result += char === state.previousTime[index] || index === 2
        ? char : String((Number(char) + offset + (index > 2 ? index - 1 : index)) % 10)
    }
    return result
  }

  function scaledDuration(ms: real): int {
    return motionEnabled ? Commons.Style.duration(Math.max(0, Math.round(ms))) : 0
  }

  function animateProperty(animation: NumberAnimation, value: real, ms: real): void {
    const current = state[animation.property]
    const duration = scaledDuration(ms)
    if (animation.running && duration > 0 && animation.to === value && animation.duration === duration) return
    animation.stop()
    if (!duration || Math.abs(value - current) < 0.001) {
      state[animation.property] = value
      return
    }
    animation.from = current
    animation.to = value
    animation.duration = duration
    animation.start()
  }

  function setPointer(x: real, y: real, valid: bool): void {
    state.pointer = Qt.point(x, y)
    state.pointerValid = valid && Number.isFinite(x) && Number.isFinite(y)
    updateHover()
  }

  function updateHover(): void {
    const point = state.pointer
    const bounds = inkRect
    const padding = options.hoverEnterPadding + (hovered ? options.hoverExitPadding : 0)
    const inside = effectsActive && visible && options.hoverEnabled && state.pointerValid
      && point.x >= bounds.x - padding && point.x <= bounds.x + bounds.width + padding
      && point.y >= bounds.y - padding && point.y <= bounds.y + bounds.height + padding
    if (inside) {
      const follow = state.lightStrength > 0.001 ? options.hoverFollowMs : 0
      animateProperty(lightXMotion, point.x, follow)
      animateProperty(lightYMotion, point.y, follow)
    } else {
      lightXMotion.stop()
      lightYMotion.stop()
    }
    state.hovered = inside
    const duration = inside ? options.hoverInMs : options.hoverOutMs
    animateProperty(hoverScaleMotion, inside && motionEnabled ? maxScale : 1, duration)
    lightMotion.easing.type = inside ? Easing.InOutQuad : Easing.OutCubic
    animateProperty(lightMotion, inside ? options.hoverLight / 100 : 0, duration)
  }

  function startShine(): bool {
    if (!motionEnabled || !shaderAvailable || !options.shineEnabled || !options.shineStrength
        || hovered || minuteActive || shineActive) return false
    state.shineProgress = 0
    state.shineGain = 1
    shineTravel.duration = scaledDuration(options.shineDurationMs)
    shineTravel.start()
    return true
  }

  function stopShine(): void {
    shineTravel.stop()
    shineFade.stop()
    state.shineGain = 0
  }

  onHoveredChanged: if (hovered && shineActive) animateProperty(shineFade, 0, 40)
  onMinuteActiveChanged: {
    if (minuteActive && shineActive) animateProperty(shineFade, 0, 40)
    animateProperty(minuteLightMotion, minuteActive ? 0.38 : 1, minuteActive ? 40 : 130)
  }
  onMotionEnabledChanged: {
    if (!state.ready) return
    if (!motionEnabled) {
      settleMinute()
      stopShine()
      minuteLightMotion.stop()
      state.minuteLightGain = 1
    }
    updateHover()
  }
  onEffectsActiveChanged: if (state.ready) updateHover()
  onVisibleChanged: if (state.ready) updateHover()
  onInkRectChanged: if (state.ready && state.pointerValid) updateHover()
  onOptionsChanged: if (state.ready) {
    if (state.effect !== options.minuteEffect || state.duration !== minuteDuration) settleMinute()
    state.effect = options.minuteEffect
    state.duration = minuteDuration
    if (!options.shineEnabled || !options.shineStrength) stopShine()
    updateHover()
  }

  Component.onCompleted: {
    state.ready = true
    state.effect = options.minuteEffect
    state.duration = minuteDuration
    if (!state.initialized) settleMinute()
  }

  QtObject {
    id: state
    property bool ready: false
    property bool initialized: false
    property string time: "00:00"
    property string previousTime: "00:00"
    property string effect: ""
    property real duration: 0
    property real minuteElapsed: 0
    property point pointer: Qt.point(0, 0)
    property bool pointerValid: false
    property bool hovered: false
    property real magnification: 1
    property real lightX: 0
    property real lightY: 0
    property real lightStrength: 0
    property real minuteLightGain: 1
    property real shineProgress: 0
    property real shineGain: 0
  }

  Loader {
    id: inter
    active: root.options.fontFamily === "Inter"
    sourceComponent: FontLoader { source: "fonts/InterVariable.ttf" }
  }

  component GlyphMetrics: TextMetrics {
    font: root.faceFont
    renderType: Text.CurveRendering
  }
  GlyphMetrics { id: zero; text: "0" }
  GlyphMetrics { id: one; text: "1" }
  GlyphMetrics { id: two; text: "2" }
  GlyphMetrics { id: three; text: "3" }
  GlyphMetrics { id: four; text: "4" }
  GlyphMetrics { id: five; text: "5" }
  GlyphMetrics { id: six; text: "6" }
  GlyphMetrics { id: seven; text: "7" }
  GlyphMetrics { id: eight; text: "8" }
  GlyphMetrics { id: nine; text: "9" }
  GlyphMetrics { id: colon; text: ":" }

  NumberAnimation { id: minuteMotion; target: state; property: "minuteElapsed" }
  NumberAnimation {
    id: hoverScaleMotion; target: state; property: "magnification"
    easing.type: Easing.Bezier; easing.bezierCurve: Commons.Style.easeOut
  }
  NumberAnimation { id: lightMotion; target: state; property: "lightStrength" }
  NumberAnimation { id: lightXMotion; target: state; property: "lightX"; easing.type: Easing.OutCubic }
  NumberAnimation { id: lightYMotion; target: state; property: "lightY"; easing.type: Easing.OutCubic }
  NumberAnimation { id: minuteLightMotion; target: state; property: "minuteLightGain"; easing.type: Easing.OutCubic }
  NumberAnimation {
    id: shineTravel; target: state; property: "shineProgress"; from: 0; to: 1
    onFinished: root.stopShine()
  }
  NumberAnimation {
    id: shineFade; target: state; property: "shineGain"; easing.type: Easing.OutCubic
    onFinished: root.stopShine()
  }

  component GlyphStrip: Item {
    id: strip
    required property string value
    property color ink: "white"
    property bool fallbackOutline: false
    width: root.maskWidth
    height: root.maskHeight

    Repeater {
      model: 5
      Text {
        required property int index
        readonly property bool colonCell: index === 2
        readonly property int metricIndex: colonCell ? 10 : Number(text)
        readonly property rect bounds: root.metrics[metricIndex].bounds
        readonly property real cellWidth: colonCell ? root.colonWidth : root.digitWidth
        readonly property real cellLeft: root.pad + (index > 2
          ? (index - 1) * root.digitWidth + root.colonWidth : index * root.digitWidth)
        x: cellLeft + (cellWidth - bounds.width) / 2 - bounds.x
        y: root.pad - root.inkTop - baselineOffset
        font: root.faceFont
        renderType: Text.CurveRendering
        textFormat: Text.PlainText
        text: strip.value[index]
        color: strip.ink
        style: strip.fallbackOutline && root.contour > 0 ? Text.Outline : Text.Normal
        styleColor: Qt.rgba(24 / 255, 32 / 255, 29 / 255, root.options.outlineOpacity / 100)
      }
    }
  }

  Item {
    id: artwork
    width: root.maskWidth
    height: root.maskHeight
    anchors.centerIn: parent
    anchors.alignWhenCentered: false
    scale: root.visualScale

    Rectangle {
      width: Math.min(artwork.width, root.inkWidth + 24)
      height: Math.min(artwork.height, root.inkHeight + 14)
      anchors.centerIn: parent
      radius: 8
      color: Qt.rgba(13 / 255, 17 / 255, 16 / 255, root.options.backingOpacity / 100)
      visible: root.backed
    }

    // The atlas has one resting row per time. Animation only moves the sampling coordinates.
    Item {
      id: atlas
      width: root.maskWidth
      height: root.maskHeight * 2
      visible: false
      GlyphStrip { value: root.drawnTime }
      GlyphStrip { y: root.maskHeight; value: root.secondaryTime }
    }

    ShaderEffectSource {
      id: glyphAtlas
      visible: false
      sourceItem: root.shaderSupported ? atlas : null
    }

    MultiEffect {
      id: blurredAtlas
      width: atlas.width
      height: atlas.height
      visible: false
      source: root.shaderSupported && root.options.shadowOpacity > 0 && root.options.shadowBlur > 0 ? glyphAtlas : null
      autoPaddingEnabled: false
      blurEnabled: source !== null
      blurMax: 16
      blur: root.options.shadowBlur / 16
    }

    ShaderEffectSource {
      id: shadowAtlas
      visible: false
      sourceItem: blurredAtlas.source ? blurredAtlas : null
    }

    ShaderEffect {
      id: clockShader
      anchors.fill: parent
      visible: root.shaderAvailable
      fragmentShader: root.shaderSupported ? Qt.resolvedUrl("ClockInk.frag.qsb") : ""

      readonly property var glyphs: glyphAtlas
      readonly property var shadows: blurredAtlas.source ? shadowAtlas : glyphAtlas
      readonly property vector4d glyphLayout: Qt.vector4d(root.pad, root.digitWidth, root.colonWidth, root.inkHeight)
      readonly property vector2d glyphArea: Qt.vector2d(width, height)
      readonly property vector4d changed: root.changedDigits
      readonly property vector4d transition: Qt.vector4d(root.minuteActive && root.options.minuteEffect === "roll" ? 1
        : root.minuteActive && root.options.minuteEffect === "dissolve" ? 2 : 0,
        root.minuteDuration > 0 ? Math.min(1, root.minuteElapsed / root.minuteDuration) : 1,
        root.tail, root.hasFragments ? 1 : 0)
      readonly property vector4d slices: Qt.vector4d(root.pulse * 0.24, root.options.sliceShift * root.pulse,
        root.options.colorSpread * root.pulse / 2, root.secondPulse ? 1 : 0)
      readonly property color ink: root.inkColor
      readonly property vector4d contrast: Qt.vector4d(root.options.inkOpacity / 100, root.contour,
        root.options.outlineOpacity / 100, root.options.shadowOpacity / 100)
      readonly property real shadowOffset: root.options.shadowOffset
      readonly property vector4d highlight: Qt.vector4d(width / 2 + (state.lightX - root.width / 2) / root.visualScale,
        height / 2 + (state.lightY - root.height / 2) / root.visualScale,
        root.options.hoverRadius * root.options.size, state.lightStrength * state.minuteLightGain)
      readonly property vector4d shimmer: Qt.vector4d(state.shineProgress, state.shineGain * root.options.shineStrength / 100,
        root.advanceWidth * root.options.shineWidth / 100, Math.tan(root.options.shineAngle * Math.PI / 180))
    }

    Loader {
      active: !root.shaderAvailable
      sourceComponent: GlyphStrip {
        value: root.drawnTime
        fallbackOutline: true
        ink: Qt.tint(root.inkColor, Qt.rgba(1, 1, 1, state.lightStrength * state.minuteLightGain * 0.55))
        opacity: root.options.inkOpacity / 100
      }
    }
  }
}
