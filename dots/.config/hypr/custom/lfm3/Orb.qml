// Native Qt Quick port of the LFM3-Omni liquid orb.
// The GLSL is the Space's fragment shader compiled with qsb (see shaders/).
// No WebEngine: this is a plain ShaderEffect on the scene graph.

import QtQuick
import QtQuick.Window

Item {
    id: root

    // Public surface.
    // state: idle | listening | thinking | speaking | loading | failed
    property string state: "idle"
    property real level: 0        // 0..1 input level from the audio meter
    property real pulse: 0        // set to 1 to send a ripple across the surface
    property real fill: 1         // 0..1 glass fill, used while a model loads
    property bool dark: true
    property bool forceFallback: false

    // Pointer in -1..1, relative to the orb centre.
    property real pointerX: 0
    property real pointerY: 0

    implicitWidth: 200
    implicitHeight: 200

    // The Space draws the orb on a canvas 2.4x its button size, so most of the
    // canvas is aura. The item size is the visible sphere; the surface bleeds
    // out around it for the glow.
    readonly property real surfaceScale: 2.4

    readonly property color colorA: _hexToColor(_stops[0])
    readonly property color colorB: _hexToColor(_stops[1])
    readonly property color colorC: _hexToColor(_stops[2])
    // Keep the effect visible while it compiles (a hidden ShaderEffect never
    // compiles), then fall back only if it errored or is still uncompiled.
    property bool _graceOver: false
    readonly property bool shaderRunning: !root.forceFallback
                                           && effect.status !== ShaderEffect.Error
                                           && (effect.status === ShaderEffect.Compiled || !root._graceOver)

    function kick(amount) {
        energy = Math.min(1, energy + amount)
    }

    function sendPulse() {
        pulseLevel = 1
    }

    // Palette from the Space (Ue.dark).
    readonly property var _palettes: ({
        dark: {
            idle: ["#2a3550", "#8fa2d8", "#e7e1f4"],
            listening: ["#053b4a", "#1fb5c9", "#c8f6ff"],
            thinking: ["#2b313b", "#9aa3b2", "#f2f4f7"],
            speaking: ["#7a2e4a", "#f07a8e", "#ffd98a"]
        },
        light: {
            idle: ["#7d8fc6", "#c3cdee", "#f4f1fb"],
            listening: ["#0f7f95", "#6fd3e3", "#e2faff"],
            thinking: ["#5a6170", "#bcc2cc", "#f7f8fa"],
            speaking: ["#d24b73", "#f7a1ae", "#ffe3a3"]
        }
    })

    // Motion presets from the Space (N).
    readonly property var _motion: ({
        idle: { speed: 0.22, swirl: 0.0, wobble: 0.022, glow: 0.55 },
        listening: { speed: 0.5, swirl: 0.15, wobble: 0.03, glow: 0.8 },
        thinking: { speed: 1.05, swirl: 1.0, wobble: 0.026, glow: 0.7 },
        speaking: { speed: 0.62, swirl: 0.22, wobble: 0.04, glow: 0.9 },
        loading: { speed: 0.22, swirl: 0.0, wobble: 0.022, glow: 0.55 },
        failed: { speed: 0.12, swirl: 0.0, wobble: 0.015, glow: 0.35 }
    })

    property real time: 0
    property real flow: Math.random() * 50
    property real smoothLevel: 0
    property real energy: 0
    property real pulseLevel: 0
    property real smoothFill: root.fill
    property real speed: 0.22
    property real swirl: 0
    property real wobble: 0.022
    property real glow: 0.55
    property real pointerAlphaX: 0
    property real pointerAlphaY: 0

    property var _stops: ["#2a3550", "#8fa2d8", "#e7e1f4"]
    property vector3d _c1: Qt.vector3d(0.165, 0.208, 0.314)
    property vector3d _c2: Qt.vector3d(0.561, 0.635, 0.847)
    property vector3d _c3: Qt.vector3d(0.906, 0.882, 0.957)

    function _hexToColor(hex) {
        return Qt.color(hex)
    }

    function _vecFromHex(hex) {
        var c = Qt.color(hex)
        return Qt.vector3d(c.r, c.g, c.b)
    }

    function _targetStops() {
        var mode = root.dark ? "dark" : "light"
        var set = root._palettes[mode]
        var key = root.state
        if (!set[key])
            key = (key === "loading" || key === "failed") ? "idle" : "thinking"
        return set[key]
    }

    function _approach(current, target, rate, dt) {
        return current + (target - current) * (1 - Math.exp(-rate * dt))
    }

    onStateChanged: {
        if (!root._motion[root.state])
            console.warn("Orb: unknown state", root.state)
        _retargetColors()
    }

    // Keep the shader colours in sync with the selected state.
    function _retargetColors() {
        var target = _targetStops()
        _stops = target
    }

    Component.onCompleted: {
        _retargetColors()
        _c1 = _vecFromHex(_stops[0])
        _c2 = _vecFromHex(_stops[1])
        _c3 = _vecFromHex(_stops[2])
    }

    function _advance(dt) {
        var preset = _motion[root.state] || _motion.idle

        speed = _approach(speed, preset.speed, 2.5, dt)
        swirl = _approach(swirl, preset.swirl, 2.0, dt)
        wobble = _approach(wobble, preset.wobble, 3.0, dt)
        glow = _approach(glow, preset.glow, 3.0, dt)

        var target = Math.max(root.level, energy)
        smoothLevel = _approach(smoothLevel, target, target > smoothLevel ? 18 : 6, dt)
        energy = Math.max(0, energy - dt * 1.4)
        pulseLevel = Math.max(0, pulseLevel - dt / 1.1)
        smoothFill = _approach(smoothFill, root.fill, 3, dt)
        pointerAlphaX = _approach(pointerAlphaX, root.pointerX, 3, dt)
        pointerAlphaY = _approach(pointerAlphaY, root.pointerY, 3, dt)

        flow += dt * speed * (1 + smoothLevel * 1.2)
        time += dt

        var stops = _targetStops()
        var t1 = _vecFromHex(stops[0])
        var t2 = _vecFromHex(stops[1])
        var t3 = _vecFromHex(stops[2])
        _c1 = Qt.vector3d(_approach(_c1.x, t1.x, 2.6, dt),
                          _approach(_c1.y, t1.y, 2.6, dt),
                          _approach(_c1.z, t1.z, 2.6, dt))
        _c2 = Qt.vector3d(_approach(_c2.x, t2.x, 2.6, dt),
                          _approach(_c2.y, t2.y, 2.6, dt),
                          _approach(_c2.z, t2.z, 2.6, dt))
        _c3 = Qt.vector3d(_approach(_c3.x, t3.x, 2.6, dt),
                          _approach(_c3.y, t3.y, 2.6, dt),
                          _approach(_c3.z, t3.z, 2.6, dt))
    }

    property double _lastFrame: 0

    readonly property bool _windowVisible: Window.window ? Window.window.visible : true

    FrameAnimation {
        running: root.visible && root._windowVisible
        onTriggered: {
            var now = Date.now()
            var dt = root._lastFrame === 0 ? 1 / 60 : Math.min(0.05, (now - root._lastFrame) / 1000)
            root._lastFrame = now
            if (dt > 0)
                root._advance(dt)
        }
    }

    onPulseChanged: {
        if (pulse > pulseLevel)
            pulseLevel = Math.min(1, pulse)
    }

    // Fallback sphere, shown if the shader cannot compile or the scene graph
    // has no shader support (for example QT_QUICK_BACKEND=software).
    Canvas {
        id: fallback
        width: root.width * root.surfaceScale
        height: root.height * root.surfaceScale
        x: (root.width - width) / 2
        y: (root.height - height) / 2
        visible: !root.shaderRunning
        renderStrategy: Canvas.Cooperative

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var w = width
            var h = height
            var s = Math.min(w, h)
            var cx = w / 2
            var cy = h / 2
            // uRadius is a fraction of the half surface, so this is 0.405 * s / 2.
            var r = 0.2025 * s

            var c1 = root.colorA
            var c2 = root.colorB
            var c3 = root.colorC
            var fillLevel = Math.max(0, Math.min(1, root.smoothFill))
            var push = 1 + 0.06 * root.smoothLevel

            // Ambient glow around the sphere.
            var glow = ctx.createRadialGradient(cx, cy, r * 0.92, cx, cy, r * 1.8)
            glow.addColorStop(0, Qt.rgba(c2.r, c2.g, c2.b, 0.30))
            glow.addColorStop(0.55, Qt.rgba(c2.r, c2.g, c2.b, 0.10))
            glow.addColorStop(1, Qt.rgba(c2.r, c2.g, c2.b, 0.0))
            ctx.fillStyle = glow
            ctx.fillRect(0, 0, w, h)

            // Sphere body.
            var sphere = ctx.createRadialGradient(cx - r * 0.34, cy - r * 0.42, r * 0.06,
                                                  cx, cy, r * 1.02)
            sphere.addColorStop(0, Qt.rgba(c3.r, c3.g, c3.b, 0.98))
            sphere.addColorStop(0.32, Qt.rgba(c2.r, c2.g, c2.b, 0.94))
            sphere.addColorStop(0.78, Qt.rgba(c1.r, c1.g, c1.b, 0.97))
            sphere.addColorStop(1, Qt.rgba(c1.r * 0.7, c1.g * 0.7, c1.b * 0.7, 0.98))
            ctx.beginPath()
            ctx.arc(cx, cy, r * push, 0, Math.PI * 2)
            ctx.fillStyle = sphere
            ctx.fill()

            // Glass surface above the liquid while a model fills the sphere.
            if (fillLevel < 0.999) {
                var lineY = cy + r - 2 * r * fillLevel
                ctx.save()
                ctx.beginPath()
                ctx.arc(cx, cy, r * push, 0, Math.PI * 2)
                ctx.clip()
                var glassFill = ctx.createLinearGradient(0, cy - r, 0, lineY)
                glassFill.addColorStop(0, "rgba(12,18,26,0.62)")
                glassFill.addColorStop(1, "rgba(12,18,26,0.40)")
                ctx.fillStyle = glassFill
                ctx.fillRect(cx - r, cy - r, 2 * r, Math.max(0, lineY - (cy - r)))
                ctx.strokeStyle = Qt.rgba(c3.r, c3.g, c3.b, 0.5)
                ctx.lineWidth = 1.2
                ctx.beginPath()
                ctx.moveTo(cx - Math.sqrt(Math.max(0, r * r - Math.pow(lineY - cy, 2))), lineY)
                ctx.lineTo(cx + Math.sqrt(Math.max(0, r * r - Math.pow(lineY - cy, 2))), lineY)
                ctx.stroke()
                ctx.restore()
            }

            // Rim and highlight.
            ctx.beginPath()
            ctx.arc(cx, cy, r * push - 0.75, 0, Math.PI * 2)
            ctx.strokeStyle = Qt.rgba(c3.r, c3.g, c3.b, 0.22)
            ctx.lineWidth = 1.5
            ctx.stroke()

            var gloss = ctx.createRadialGradient(cx - r * 0.3, cy - r * 0.38, 0,
                                                 cx - r * 0.3, cy - r * 0.38, r * 0.62)
            gloss.addColorStop(0, "rgba(255,255,255,0.42)")
            gloss.addColorStop(1, "rgba(255,255,255,0)")
            ctx.beginPath()
            ctx.arc(cx, cy, r * push, 0, Math.PI * 2)
            ctx.fillStyle = gloss
            ctx.fill()

            var spec = ctx.createRadialGradient(cx - r * 0.34, cy - r * 0.42, 0,
                                                cx - r * 0.34, cy - r * 0.42, r * 0.28)
            spec.addColorStop(0, "rgba(255,255,255,0.9)")
            spec.addColorStop(0.45, "rgba(255,255,255,0.20)")
            spec.addColorStop(1, "rgba(255,255,255,0)")
            ctx.beginPath()
            ctx.arc(cx, cy, r * push, 0, Math.PI * 2)
            ctx.fillStyle = spec
            ctx.fill()
        }

        Connections {
            target: root
            function onColorAChanged() { fallback.requestPaint() }
            function onColorBChanged() { fallback.requestPaint() }
            function onColorCChanged() { fallback.requestPaint() }
            function onSmoothFillChanged() { fallback.requestPaint() }
            function onSmoothLevelChanged() { fallback.requestPaint() }
        }
    }

    Timer {
        interval: 900
        running: true
        onTriggered: root._graceOver = true
    }

    ShaderEffect {
        id: effect
        width: root.width * root.surfaceScale
        height: root.height * root.surfaceScale
        x: (root.width - width) / 2
        y: (root.height - height) / 2
        visible: root.shaderRunning
        blending: true
        supportsAtlasTextures: false

        // Device pixels, so the anti-aliased rim stays one physical pixel wide.
        property vector2d uRes: Qt.vector2d(effect.width * _dpr, effect.height * _dpr)
        property vector2d uPointer: Qt.vector2d(root.pointerAlphaX, root.pointerAlphaY)
        property real uTime: root.time
        property real uFlow: root.flow
        property real uLevel: root.smoothLevel
        property real uPulse: root.pulseLevel
        property real uSwirl: root.swirl
        property real uWobble: root.wobble
        property real uGlow: root.glow
        property real uDark: root.dark ? 1 : 0
        property real uRadius: 0.405
        property real uFill: root.smoothFill
        property vector3d uC1: root._c1
        property vector3d uC2: root._c2
        property vector3d uC3: root._c3

        readonly property real _dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1

        vertexShader: "shaders/orb.vert.qsb"
        fragmentShader: "shaders/orb.frag.qsb"

        onStatusChanged: {
            if (status === ShaderEffect.Error)
                console.warn("Orb: shader failed, using fallback:", log)
        }
    }
}
