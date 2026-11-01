//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
// Recorder popup — Android-style voice recorder for the ii quick panel.
// Opens from the "Voice recorder" toggle (right click) or directly:
//   qs -n -p ~/.config/hypr/custom/MicRecorder.qml
//
// Records WAV via rec-mic.sh (segmented pause/resume, lossless concat), shows a
// live level meter through cava, and plays/renames/deletes past recordings.

import QtQuick
import QtQuick.Controls
import QtMultimedia
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

PanelWindow {
    id: root
    visible: true
    color: "transparent"

    WlrLayershell.namespace: "qs-mic-recorder"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    readonly property var activeScreen: Quickshell.screens.find(
        s => s.name === Hyprland.focusedMonitor?.name
    )
    screen: activeScreen
    anchors { top: true; bottom: true; left: true; right: true }

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string cacheDir: home + "/.cache/qs-recorder"
    readonly property string statePath: cacheDir + "/state.json"
    readonly property string configPath: home + "/.config/illogical-impulse/recorder.json"
    readonly property string scriptPath: home + "/.config/hypr/custom/scripts/rec-mic.sh"
    readonly property string cavaConfigPath: home + "/.config/hypr/custom/qs-recorder/cava.conf"

    property string audioDir: home + "/Music/Recordings"
    property var micState: ({})
    property double nowSec: Date.now() / 1000

    readonly property var mic: micState.mic ?? null
    readonly property bool micRunning: mic !== null && mic.running === true
    readonly property bool micPaused: micRunning && mic.paused === true
    readonly property real elapsed: {
        if (!micRunning) return 0
        const done = mic.elapsed ?? 0
        if (micPaused) return done
        return done + Math.max(0, nowSec - (mic.segmentStart ?? nowSec))
    }

    property var bars: []
    readonly property int barCount: 32

    property string selectedPath: ""
    property string renameText: ""
    property bool renaming: false
    property bool confirmingDelete: false
    property bool seeking: false

    function clock(seconds) {
        const t = Math.floor(seconds + 0.5)
        if (t >= 3600)
            return Math.floor(t / 3600) + ":" + String(Math.floor(t / 60) % 60).padStart(2, "0") + ":" + String(t % 60).padStart(2, "0")
        return Math.floor(t / 60) + ":" + String(t % 60).padStart(2, "0")
    }

    function humanSize(bytes) {
        if (!bytes) return "0 B"
        if (bytes < 1048576) return (bytes / 1024).toFixed(0) + " KB"
        return (bytes / 1048576).toFixed(1) + " MB"
    }

    function reloadState(raw) {
        try {
            root.micState = JSON.parse(raw || "{}")
        } catch (e) {
            root.micState = ({})
        }
    }

    function reloadConfig(raw) {
        try {
            const c = JSON.parse(raw || "{}")
            if (c.audioDir) root.audioDir = c.audioDir
        } catch (e) {}
    }

    function run(command) {
        Quickshell.execDetached(["bash", root.scriptPath, command])
    }

    function selectFile(path) {
        if (!path) return
        root.renaming = false
        root.confirmingDelete = false
        if (root.selectedPath === path) {
            togglePlayback()
            return
        }
        root.selectedPath = path
        player.stop()
        player.source = Qt.resolvedUrl(path)
        player.play()
    }

    function togglePlayback() {
        if (!root.selectedPath) return
        if (player.playbackState === MediaPlayer.PlayingState) {
            player.pause()
        } else {
            if (!player.source || player.source.toString() === "")
                player.source = Qt.resolvedUrl(root.selectedPath)
            player.play()
        }
    }

    function startRename() {
        if (!root.selectedPath) return
        root.renameText = root.selectedPath.split("/").pop()
        root.renaming = true
        Qt.callLater(() => renameField.forceActiveFocus())
    }

    function commitRename() {
        const oldPath = root.selectedPath
        let name = root.renameText.trim()
        if (!oldPath || name === "" || name === oldPath.split("/").pop()) {
            root.renaming = false
            return
        }
        if (!name.toLowerCase().endsWith(".wav")) name += ".wav"
        const newPath = oldPath.substring(0, oldPath.lastIndexOf("/") + 1) + name
        renameProc.command = ["mv", "-f", oldPath, newPath]
        renameProc.running = true
        root.selectedPath = newPath
        root.renaming = false
    }

    function deleteSelected() {
        if (!root.selectedPath) return
        if (!root.confirmingDelete) {
            root.confirmingDelete = true
            return
        }
        player.stop()
        player.source = ""
        rmProc.command = ["rm", "-f", root.selectedPath]
        rmProc.running = true
        root.selectedPath = ""
        root.confirmingDelete = false
    }

    function revealSelected() {
        if (!root.selectedPath) return
        Quickshell.execDetached(["dolphin", "--select", root.selectedPath])
    }

    function openFolder() {
        Quickshell.execDetached(["xdg-open", root.audioDir])
    }

    // --- data ---------------------------------------------------------------
    FileView {
        id: stateFile
        path: root.statePath
        watchChanges: true
        onLoaded: root.reloadState(text())
        onTextChanged: root.reloadState(text())
        onLoadFailed: root.micState = ({})
    }

    FileView {
        id: configFile
        path: root.configPath
        watchChanges: true
        onLoaded: root.reloadConfig(text())
        onTextChanged: root.reloadConfig(text())
    }

    FolderListModel {
        id: recordings
        folder: Qt.resolvedUrl("file://" + root.audioDir)
        nameFilters: ["*.wav"]
        showDirs: false
        sortField: FolderListModel.Time
        sortReversed: true
    }

    MediaPlayer {
        id: player
        audioOutput: AudioOutput {}
        onPlaybackStateChanged: {
            if (playbackState === MediaPlayer.StoppedState && !root.seeking)
                root.seeking = false
        }
        onErrorOccurred: (error, message) => console.log("[MicRecorder] playback error:", error, message)
    }

    Process {
        id: renameProc
        onExited: recordings.folder = Qt.resolvedUrl("file://" + root.audioDir)
    }

    Process {
        id: rmProc
        onExited: {
            recordings.folder = Qt.resolvedUrl("file://" + root.audioDir)
        }
    }

    Process {
        id: cavaProc
        running: root.micRunning
        command: ["cava", "-p", root.cavaConfigPath]
        onRunningChanged: {
            if (!cavaProc.running) root.bars = []
        }
        stdout: SplitParser {
            onRead: data => {
                const values = data.split(";").map(v => parseFloat(v)).filter(v => !isNaN(v))
                if (values.length > 0)
                    root.bars = values
            }
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.micRunning
        onTriggered: root.nowSec = Date.now() / 1000
    }

    Timer {
        interval: 600
        running: root.selectedPath === "" && recordings.count > 0 && !root.micRunning
        repeat: false
        onTriggered: {
            const first = recordings.get(0, "filePath") || ""
            root.selectedPath = first
            if (first !== "") player.source = Qt.resolvedUrl(first)
        }
    }

    // --- UI -----------------------------------------------------------------
    Rectangle {
        anchors.fill: parent
        color: "#8a000000"
        MouseArea { anchors.fill: parent; onClicked: Qt.quit() }
    }

    Rectangle {
        id: card
        width: 580
        height: Math.min(parent.height - 80, 660)
        radius: 18
        color: "#f0212136"
        border { color: "#30ffffff"; width: 1 }
        anchors.centerIn: parent
        focus: true
        activeFocusOnTab: true

        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Escape) {
                if (root.renaming) { root.renaming = false }
                else if (root.confirmingDelete) { root.confirmingDelete = false }
                else Qt.quit()
                event.accepted = true
            } else if (event.key === Qt.Key_Space && !root.renaming) {
                root.togglePlayback()
                event.accepted = true
            }
        }

        Column {
            id: layout
            anchors.fill: parent
            anchors.margins: 24
            spacing: 14

            // Header
            Item {
                width: parent.width
                height: 28

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Recorder"
                    color: "#ffffff"
                    font.pixelSize: 20
                    font.bold: true
                }

                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "✕"
                    color: "#a9b4d0"
                    font.pixelSize: 18
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -8
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Qt.quit()
                    }
                }
            }

            // Live recording pane
            Rectangle {
                width: parent.width
                height: 156
                radius: 14
                color: "#26263c"
                border { color: root.micRunning ? "#4d6bff" : "#33344d"; width: 1 }

                Column {
                    anchors.centerIn: parent
                    spacing: 10
                    width: parent.width - 36

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.micRunning
                            ? (root.micPaused ? "Paused" : "Recording") + " · " + root.clock(root.elapsed)
                            : "Tap record to capture a voice memo"
                        color: root.micRunning ? "#ffffff" : "#a9b4d0"
                        font.pixelSize: root.micRunning ? 24 : 14
                        font.bold: root.micRunning
                    }

                    // Level meter
                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        height: 34
                        spacing: 3

                        Repeater {
                            model: root.barCount
                            Rectangle {
                                required property int index
                                width: 6
                                radius: 3
                                color: root.micRunning && !root.micPaused ? "#8f9bff" : "#3d3f5c"
                                height: {
                                    if (!root.micRunning || root.micPaused) return 4
                                    const v = root.bars[index] ?? 0
                                    return 4 + Math.min(1, v / 900) * 30
                                }
                                anchors.verticalCenter: parent.verticalCenter
                                Behavior on height {
                                    animation: NumberAnimation { duration: 90; easing.type: Easing.OutQuad }
                                }
                            }
                        }
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 12

                        RecordButton {
                            visible: !root.micRunning
                            symbol: "mic"
                            label: "Record"
                            accent: "#ff6b6b"
                            onClicked: root.run("start")
                        }

                        RecordButton {
                            visible: root.micRunning
                            symbol: root.micPaused ? "play_arrow" : "pause"
                            label: root.micPaused ? "Resume" : "Pause"
                            onClicked: root.run(root.micPaused ? "resume" : "pause")
                        }

                        RecordButton {
                            visible: root.micRunning
                            symbol: "stop"
                            label: "Stop"
                            onClicked: root.run("stop")
                        }

                        RecordButton {
                            visible: root.micRunning
                            symbol: "delete"
                            label: "Discard"
                            subtle: true
                            onClicked: root.run("stop --discard")
                        }
                    }
                }
            }

            // Playback bar
            Rectangle {
                width: parent.width
                height: root.selectedPath !== "" ? 62 : 0
                visible: height > 0
                radius: 12
                color: "#1c1c2e"

                Row {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 10

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: player.playbackState === MediaPlayer.PlayingState ? "❚❚" : "▶"
                        color: "#cfd6ea"
                        font.pixelSize: 16
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.togglePlayback()
                        }
                    }

                    Slider {
                        id: seek
                        width: parent.width - 190
                        anchors.verticalCenter: parent.verticalCenter
                        from: 0
                        to: player.duration > 0 ? player.duration : 1
                        value: player.position
                        enabled: player.duration > 0
                        onMoved: {
                            root.seeking = true
                            player.position = value
                        }
                        onPressedChanged: {
                            if (!pressed) root.seeking = false
                        }

                        background: Rectangle {
                            x: seek.leftPadding
                            y: seek.topPadding + seek.availableHeight / 2 - height / 2
                            width: seek.availableWidth
                            height: 4
                            radius: 2
                            color: "#33344d"
                            Rectangle {
                                width: seek.visualPosition * parent.width
                                height: parent.height
                                radius: 2
                                color: "#8f9bff"
                            }
                        }

                        handle: Rectangle {
                            x: seek.leftPadding + seek.visualPosition * (seek.availableWidth - width)
                            y: seek.topPadding + seek.availableHeight / 2 - height / 2
                            width: 12
                            height: 12
                            radius: 6
                            color: seek.enabled ? "#eef1fa" : "#5b5f78"
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.clock((player.position ?? 0) / 1000) + " / " + root.clock((player.duration ?? 0) / 1000)
                        color: "#a9b4d0"
                        font.pixelSize: 12
                    }
                }
            }

            // Recordings list
            Item {
                width: parent.width
                height: parent.height - 28 - 156 - 62 - 76 - layout.spacing * 4

                Text {
                    id: listHeader
                    text: "Recordings"
                    color: "#a9b4d0"
                    font.pixelSize: 12
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: 0.5
                }

                Rectangle {
                    id: emptyState
                    anchors.top: listHeader.bottom
                    anchors.topMargin: 10
                    width: parent.width
                    height: 60
                    radius: 10
                    color: "#1a1a2b"
                    visible: recordings.count === 0
                    Text {
                        anchors.centerIn: parent
                        text: "No recordings yet"
                        color: "#6d7591"
                        font.pixelSize: 13
                    }
                }

                ListView {
                    id: list
                    anchors.top: listHeader.bottom
                    anchors.topMargin: 8
                    width: parent.width
                    height: parent.height - listHeader.height - 8
                    clip: true
                    spacing: 4
                    model: recordings

                    delegate: Rectangle {
                        required property string fileName
                        required property string filePath
                        required property real fileSize
                        required property date fileModified

                        width: list.width
                        height: 44
                        radius: 9
                        color: root.selectedPath === filePath
                            ? "#33344d"
                            : (rowMouse.containsMouse ? "#282840" : "transparent")

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            spacing: 10

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "🎙"
                                font.pixelSize: 14
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 130
                                spacing: 1
                                Text {
                                    width: parent.width
                                    text: fileName
                                    color: "#eef1fa"
                                    font.pixelSize: 13
                                    elide: Text.ElideMiddle
                                }
                                Text {
                                    text: fileModified.toLocaleString(Qt.locale(), "yyyy-MM-dd HH:mm") + " · " + root.humanSize(fileSize)
                                    color: "#7f88a3"
                                    font.pixelSize: 11
                                }
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.selectedPath === filePath && player.playbackState === MediaPlayer.PlayingState ? "❚❚" : "▶"
                                color: "#a9b4d0"
                                font.pixelSize: 14
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -8
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.selectFile(filePath)
                                }
                            }
                        }

                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton
                            onClicked: root.selectFile(filePath)
                        }
                    }
                }
            }

            // Footer / item actions
            Item {
                width: parent.width
                height: 40

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8
                    visible: !root.renaming

                    SmallButton {
                        label: "Open folder"
                        onClicked: root.openFolder()
                    }
                    SmallButton {
                        label: "Reveal"
                        enabled: root.selectedPath !== ""
                        onClicked: root.revealSelected()
                    }
                    SmallButton {
                        label: "Rename"
                        enabled: root.selectedPath !== ""
                        onClicked: root.startRename()
                    }
                    SmallButton {
                        label: root.confirmingDelete ? "Confirm delete" : "Delete"
                        danger: root.confirmingDelete
                        enabled: root.selectedPath !== ""
                        onClicked: root.deleteSelected()
                    }
                }

                Row {
                    anchors.fill: parent
                    spacing: 8
                    visible: root.renaming

                    TextField {
                        id: renameField
                        width: parent.width - 150
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.renameText
                        color: "#eef1fa"
                        selectByMouse: true
                        onTextEdited: root.renameText = text
                        onAccepted: root.commitRename()
                        Keys.onEscapePressed: root.renaming = false
                        background: Rectangle {
                            radius: 8
                            color: "#1c1c2e"
                            border { color: "#4d6bff"; width: 1 }
                        }
                    }

                    SmallButton {
                        label: "Save"
                        onClicked: root.commitRename()
                    }
                    SmallButton {
                        label: "Cancel"
                        onClicked: root.renaming = false
                    }
                }
            }
        }
    }

    component RecordButton: Rectangle {
        id: button
        property string symbol
        property string label
        property color accent: "#5b6cff"
        property bool subtle: false
        signal clicked()

        width: Math.max(64, labelText.implicitWidth + 28)
        height: 40
        radius: 20
        color: button.subtle
            ? (buttonMouse.containsMouse ? "#33344d" : "#26263c")
            : (buttonMouse.containsMouse ? Qt.lighter(button.accent, 1.15) : button.accent)
        border { color: button.subtle ? "#3a3b55" : "transparent"; width: 1 }

        Row {
            anchors.centerIn: parent
            spacing: 6
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: button.symbol === "mic" ? "🎙" : (button.symbol === "pause" ? "❚❚" : (button.symbol === "play_arrow" ? "▶" : (button.symbol === "stop" ? "■" : "🗑")))
                color: "#ffffff"
                font.pixelSize: 13
            }
            Text {
                id: labelText
                anchors.verticalCenter: parent.verticalCenter
                text: button.label
                color: "#ffffff"
                font.pixelSize: 13
                font.bold: !button.subtle
            }
        }

        MouseArea {
            id: buttonMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.clicked()
        }
    }

    component SmallButton: Button {
        id: small
        property string label
        property bool danger: false
        implicitHeight: 32
        padding: 12
        opacity: enabled ? 1 : 0.45
        background: Rectangle {
            radius: 16
            color: small.danger ? "#5a2330" : (small.hovered ? "#33344d" : "#26263c")
            border { color: small.danger ? "#ff8a8a" : "#3a3b55"; width: 1 }
        }
        contentItem: Text {
            text: small.label
            color: small.danger ? "#ffb3b3" : "#cfd6ea"
            font.pixelSize: 12
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    Component.onCompleted: {
        Qt.callLater(() => card.forceActiveFocus())
        root.reloadState("")
    }
}
