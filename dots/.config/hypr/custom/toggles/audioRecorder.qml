// Microphone / voice-recorder quick toggle model.
// Installed by dots-hyprland-extensions into ~/.config/hypr/custom/toggles/ and
// loaded at runtime by the ii/waffle catch-all delegate.
//
// Left click starts/stops a WAV recording via rec-mic.sh; right click opens the
// Recorder popup (level meter, pause/resume, list/play/rename/delete).

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common.models.quickToggles

QuickToggleModel {
    id: model

    property var shellState: null

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string statePath: home + "/.cache/qs-recorder/state.json"
    readonly property string scriptPath: home + "/.config/hypr/custom/scripts/rec-mic.sh"
    readonly property string popupPath: home + "/.config/hypr/custom/MicRecorder.qml"

    property var state: ({})
    property double nowSec: Date.now() / 1000

    readonly property var mic: model.state.mic ?? null
    readonly property bool running: model.mic !== null && model.mic.running === true
    readonly property bool paused: model.running && model.mic.paused === true
    readonly property real elapsed: {
        if (!model.running) return 0
        const done = model.mic.elapsed ?? 0
        if (model.paused) return done
        return done + Math.max(0, model.nowSec - (model.mic.segmentStart ?? model.nowSec))
    }

    name: "Voice recorder"
    icon: model.paused ? "pause_circle" : (model.running ? "stop_circle" : "mic")
    toggled: model.running
    available: true
    hasStatusText: true
    statusText: model.running
        ? (model.paused ? "Paused · " : "Recording · ") + model.clock(model.elapsed)
        : "Microphone · WAV"
    tooltipText: model.running
        ? (model.paused ? "Paused" : "Recording") + " · " + model.clock(model.elapsed) + " — click to stop, right-click for the Recorder"
        : "Voice recorder — click to record, right-click for the Recorder"
    mainAction: () => model.toggleRecording()
    altAction: () => model.openRecorder()
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

    function toggleRecording() {
        Quickshell.execDetached(["bash", model.scriptPath, model.running ? "stop" : "start"])
    }

    function openRecorder() {
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

    property Timer ticker: Timer {
        interval: 1000
        repeat: true
        running: model.running
        onTriggered: model.nowSec = Date.now() / 1000
    }

    property Timer openDelayTimer: Timer {
        interval: 280
        repeat: false
        onTriggered: Quickshell.execDetached(["qs", "-n", "-p", model.popupPath])
    }

    Component.onCompleted: model.reloadState()
}
