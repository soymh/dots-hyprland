import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

// Confirmation popup shown when CTRL+SUPER+L is pressed while the
// LLM (llama-server) is already running. Y = unload + kill, N = cancel.
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

PanelWindow {
    id: root
    visible: true
    color: "transparent"

    WlrLayershell.namespace: "qs-llm-confirm"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    readonly property var activeScreen: Quickshell.screens.find(
        s => s.name === Hyprland.focusedMonitor?.name
    )
    screen: activeScreen

    anchors { top: true; bottom: true; left: true; right: true }

    function unload() {
        Quickshell.execDetached(["/home/soymh/.local/bin/llm-toggle.sh", "force-stop"])
        Qt.quit()
    }

    Rectangle {
        anchors.fill: parent
        color: "#8a000000"
        MouseArea { anchors.fill: parent; onClicked: Qt.quit() }
    }

    Rectangle {
        id: card
        width: 460
        height: 170
        radius: 14
        color: "#f0212136"
        border { color: "#30ffffff"; width: 1 }
        anchors.centerIn: parent
        focus: true
        activeFocusOnTab: true

        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Y || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.unload()
                event.accepted = true
            } else if (event.key === Qt.Key_N || event.key === Qt.Key_Escape) {
                Qt.quit()
                event.accepted = true
            }
        }

        Column {
            anchors.fill: parent
            anchors.margins: 26
            spacing: 10

            Text {
                text: "Unload LLM server?"
                color: "#ffffff"
                font.pixelSize: 19
                font.bold: true
            }

            Text {
                text: "This unloads the model and stops llama-server."
                color: "#ccd6ff"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
                width: parent.width
            }

            Row {
                spacing: 12
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.topMargin: 12

                Button { text: "Unload"; onClicked: root.unload() }
                Button { text: "Cancel"; onClicked: Qt.quit() }
            }

            Text {
                text: "or press  y = unload    n = cancel"
                color: "#8fa3ff"
                font.pixelSize: 12
                font.italic: true
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    Component.onCompleted: {
        Qt.callLater(() => card.forceActiveFocus())
    }
}