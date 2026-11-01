// Screen-recording quick toggle model.
// Installed by dots-hyprland-extensions into ~/.config/hypr/custom/toggles/ and
// loaded at runtime by the ii/waffle catch-all delegate, so it never lives
// inside the quickshell tree that dots-hyprland syncs with --delete.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common.models.quickToggles

QuickToggleModel {
    id: model

    // Injected by the panel delegate so we can close the panel before slurp.
    property var shellState: null

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string statePath: home + "/.cache/qs-recorder/state.json"
    readonly property string configPath: home + "/.config/illogical-impulse/recorder.json"
    readonly property string scriptPath: home + "/.config/hypr/custom/scripts/rec-screen.sh"
    readonly property string optionsPath: home + "/.config/hypr/custom/ScreenRecorderOptions.qml"

    property var state: ({})
    property var config: ({})
    property double nowSec: Date.now() / 1000

    readonly property var screen: model.state.screen ?? null
    readonly property bool running: model.screen !== null && model.screen.running === true
    readonly property real elapsed: model.running
        ? Math.max(0, model.nowSec - (model.screen.started ?? model.nowSec))
        : 0

    readonly property string area: model.config.screenArea ?? "region"
    readonly property string audio: model.config.screenAudio ?? "system"

    readonly property string areaLabel: model.area === "full" ? "Full screen" : "Region"
    readonly property string audioLabel: {
        switch (model.audio) {
            case "silent": return "No audio"
            case "mic": return "Microphone"
            case "both": return "System + mic"
            default: return "System audio"
        }
    }

    name: "Screen record"
    icon: model.running ? "stop_circle" : "screen_record"
    toggled: model.running
    available: true
    hasStatusText: true
    statusText: model.running
        ? "Recording · " + model.clock(model.elapsed)
        : model.areaLabel + " · " + model.audioLabel
    tooltipText: model.running
        ? "Recording · " + model.clock(model.elapsed) + " — click to stop"
        : "Screen record (" + model.areaLabel + ", " + model.audioLabel + ") — click to start, right-click for options"
    mainAction: () => model.toggleRecording()
    altAction: () => model.openOptions()
    hasMenu: false

    function clock(seconds) {
        const t = Math.floor(seconds + 0.5)
        if (t >= 3600)
            return Math.floor(t / 3600) + ":" + String(Math.floor(t / 60) % 60).padStart(2, "0") + ":" + String(t % 60).padStart(2, "0")
        return Math.floor(t / 60) + ":" + String(t % 60).padStart(2, "0")
    }

    function closePanel() {
        if (model.shellState)
            model.shellState.sidebarRightOpen = false
    }

    property var pendingArgs: []
    function runAfterPanelClose(args) {
        model.pendingArgs = args
        model.delayTimer.restart()
    }

    function toggleRecording() {
        if (model.running) {
            Quickshell.execDetached(["bash", model.scriptPath, "stop"])
        } else {
            model.closePanel()
            model.runAfterPanelClose(["start"])
        }
    }

    function openOptions() {
        model.closePanel()
        model.openDelayTimer.restart()
    }

    property FileView stateFile: FileView {
        path: model.statePath
        watchChanges: true
        onTextChanged: model.reloadState()
        onLoaded: model.reloadState()
        onLoadFailed: model.state = ({})
    }

    property FileView configFile: FileView {
        path: model.configPath
        watchChanges: true
        onTextChanged: model.reloadConfig()
        onLoaded: model.reloadConfig()
    }

    // Belt and braces: atomic file replacements can kill inotify watches, so
    // re-read the state file cheaply even if watchChanges stops firing.
    readonly property Timer statePoller: Timer {
        interval: 2000
        repeat: true
        running: true
        onTriggered: model.stateFile.reload()
    }

    function reloadState() {
        try {
            model.state = JSON.parse(model.stateFile.text() || "{}")
        } catch (e) {
            model.state = ({})
        }
    }

    function reloadConfig() {
        try {
            model.config = JSON.parse(model.configFile.text() || "{}")
        } catch (e) {
            model.config = ({})
        }
    }

    property Timer ticker: Timer {
        interval: 1000
        repeat: true
        running: model.running
        onTriggered: model.nowSec = Date.now() / 1000
    }

    property Timer delayTimer: Timer {
        interval: 280
        repeat: false
        onTriggered: Quickshell.execDetached(["bash", model.scriptPath].concat(model.pendingArgs))
    }

    property Timer openDelayTimer: Timer {
        interval: 280
        repeat: false
        onTriggered: Quickshell.execDetached(["qs", "-n", "-p", model.optionsPath])
    }

    Component.onCompleted: {
        model.reloadState()
        model.reloadConfig()
    }
}
