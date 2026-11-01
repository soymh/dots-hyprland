//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

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

    WlrLayershell.namespace: "qs-task-entry"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    readonly property var activeScreen: Quickshell.screens.find(
        s => s.name === Hyprland.focusedMonitor?.name
    )
    screen: activeScreen

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    Rectangle {
        anchors.fill: parent
        color: "#80000000"

        MouseArea {
            anchors.fill: parent
            onClicked: Qt.quit()
        }
    }

    Rectangle {
        width: 520
        height: 64
        radius: 12
        color: "#f02a2a3e"
        border.color: "#40ffffff"
        border.width: 1

        anchors.centerIn: parent

        TextField {
            id: taskInput
            anchors.fill: parent
            anchors.margins: 12
            placeholderText: "New task… (or proj:name Buy milk)"
            color: "#ffffff"
            placeholderTextColor: "#80ffffff"
            font.pixelSize: 18
            background: null
            verticalAlignment: TextInput.AlignVCenter

            Keys.onPressed: (event) => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    saveTask()
                } else if (event.key === Qt.Key_Escape) {
                    Qt.quit()
                }
            }
        }
    }

    function saveTask() {
        var text = taskInput.text.trim()
        if (text === "") {
            Qt.quit()
            return
        }

        var match = text.match(/^([\w-]+):(.+)$/)
        var args = ["task", "add"]
        if (match) {
            args.push("project:" + match[1])
            args.push(match[2])
        } else {
            args.push(text)
        }

        Quickshell.execDetached(args)
        Qt.quit()
    }

    Component.onCompleted: {
        Qt.callLater(() => { taskInput.forceActiveFocus() })
    }
}