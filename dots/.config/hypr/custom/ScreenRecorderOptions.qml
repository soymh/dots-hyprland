//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
// Screen-recording options popup (right-click on the Screen record toggle).
// Lets you pick area + audio source for the next recording; the choice is
// remembered in ~/.config/illogical-impulse/recorder.json by rec-screen.sh.
//
// Installed by dots-hyprland-extensions; launches as `qs -p <this file>`.

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

PanelWindow {
    id: root
    visible: true
    color: "transparent"

    WlrLayershell.namespace: "qs-screen-recorder-options"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    readonly property var activeScreen: Quickshell.screens.find(
        s => s.name === Hyprland.focusedMonitor?.name
    )
    screen: activeScreen

    anchors { top: true; bottom: true; left: true; right: true }

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string configPath: home + "/.config/illogical-impulse/recorder.json"
    readonly property string statePath: home + "/.cache/qs-recorder/state.json"
    readonly property string scriptPath: home + "/.config/hypr/custom/scripts/rec-screen.sh"

    property string area: "region"
    property string audio: "system"
    property bool running: false

    function close() { Qt.quit() }

    function startRecording() {
        Quickshell.execDetached(["bash", scriptPath, "start", "--area", root.area, "--audio", root.audio])
        Qt.quit()
    }

    function stopRecording() {
        Quickshell.execDetached(["bash", scriptPath, "stop"])
        Qt.quit()
    }

    FileView {
        id: configFile
        path: root.configPath
        onLoaded: root.applyConfig(text())
        onTextChanged: root.applyConfig(text())
    }

    FileView {
        id: stateFile
        path: root.statePath
        watchChanges: true
        onLoaded: root.applyState(text())
        onTextChanged: root.applyState(text())
    }

    function applyConfig(raw) {
        try {
            const c = JSON.parse(raw || "{}")
            if (c.screenArea === "region" || c.screenArea === "full") root.area = c.screenArea
            if (["silent", "system", "mic", "both"].includes(c.screenAudio)) root.audio = c.screenAudio
        } catch (e) {}
    }

    function applyState(raw) {
        try {
            const s = JSON.parse(raw || "{}")
            root.running = s.screen !== null && s.screen !== undefined && s.screen.running === true
        } catch (e) {
            root.running = false
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "#8a000000"
        MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    Rectangle {
        id: card
        width: 520
        height: content.implicitHeight + 52
        radius: 16
        color: "#f0212136"
        border { color: "#30ffffff"; width: 1 }
        anchors.centerIn: parent
        focus: true
        activeFocusOnTab: true

        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Escape) {
                root.close()
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (root.running) root.stopRecording()
                else root.startRecording()
                event.accepted = true
            }
        }

        Column {
            id: content
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 26 }
            spacing: 16

            Text {
                text: root.running ? "Screen recording in progress" : "Record the screen"
                color: "#ffffff"
                font.pixelSize: 19
                font.bold: true
            }

            Text {
                text: "Area"
                color: "#a9b4d0"
                font.pixelSize: 12
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 0.5
            }

            Row {
                spacing: 8
                OptionButton { label: "Region (drag)"; selected: root.area === "region"; onClicked: root.area = "region" }
                OptionButton { label: "Full screen"; selected: root.area === "full"; onClicked: root.area = "full" }
            }

            Text {
                text: "Audio"
                color: "#a9b4d0"
                font.pixelSize: 12
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 0.5
            }

            Row {
                spacing: 8
                OptionButton { label: "None"; selected: root.audio === "silent"; onClicked: root.audio = "silent" }
                OptionButton { label: "System"; selected: root.audio === "system"; onClicked: root.audio = "system" }
                OptionButton { label: "Mic"; selected: root.audio === "mic"; onClicked: root.audio = "mic" }
                OptionButton { label: "System + mic"; selected: root.audio === "both"; onClicked: root.audio = "both" }
            }

            Row {
                spacing: 10
                anchors.horizontalCenter: parent.horizontalCenter

                Button {
                    id: startButton
                    text: root.running ? "Stop recording" : "Start recording"
                    implicitHeight: 38
                    padding: 20
                    onClicked: root.running ? root.stopRecording() : root.startRecording()
                    background: Rectangle {
                        radius: 19
                        color: startButton.down ? "#4a5ae8" : (startButton.hovered ? "#6b7bff" : "#5b6cff")
                    }
                    contentItem: Text {
                        text: startButton.text
                        color: "#ffffff"
                        font.pixelSize: 13
                        font.bold: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Button {
                    id: cancelButton
                    text: "Cancel"
                    implicitHeight: 38
                    padding: 18
                    onClicked: root.close()
                    background: Rectangle {
                        radius: 19
                        color: cancelButton.hovered ? "#33344d" : "#26263c"
                        border { color: "#3a3b55"; width: 1 }
                    }
                    contentItem: Text {
                        text: cancelButton.text
                        color: "#cfd6ea"
                        font.pixelSize: 13
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }

            Text {
                text: root.running
                    ? "A recording is already running. Stop it, or Esc to close."
                    : "Esc to close · Enter to start · saved to your Videos folder"
                color: "#8fa3ff"
                font.pixelSize: 12
                font.italic: true
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    component OptionButton: Button {
        id: option
        property string label
        property bool selected: false
        implicitHeight: 34
        padding: 14
        text: label
        font.pixelSize: 13
        background: Rectangle {
            radius: 17
            color: option.selected ? "#5b6cff" : (option.hovered ? "#33344d" : "#26263c")
            border { color: option.selected ? "#8f9bff" : "#3a3b55"; width: 1 }
        }
        contentItem: Text {
            text: option.label
            color: option.selected ? "#ffffff" : "#cfd6ea"
            font: option.font
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    Component.onCompleted: Qt.callLater(() => card.forceActiveFocus())
}
