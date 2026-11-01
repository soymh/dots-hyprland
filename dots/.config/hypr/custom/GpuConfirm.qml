import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

// GPU mode switch confirmation. Reads current envycontrol mode and offers:
//   Y / Enter = switch + reboot now
//   S         = switch only (takes effect on next reboot)
//   N / Esc   = cancel
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

PanelWindow {
    id: root
    visible: true
    color: "transparent"

    WlrLayershell.namespace: "qs-gpu-confirm"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    readonly property var activeScreen: Quickshell.screens.find(
        s => s.name === Hyprland.focusedMonitor?.name
    )
    screen: activeScreen

    anchors { top: true; bottom: true; left: true; right: true }

    property string currentMode: "integrated"
    readonly property string targetMode: currentMode === "hybrid" ? "integrated" : "hybrid"
    readonly property string targetLabel: targetMode === "hybrid" ? "Hybrid (dGPU on)" : "Integrated (iGPU only)"

    function notify(summary, body) {
        Quickshell.execDetached(["notify-send", "-a", "GPU Toggle", summary, body])
    }

    function switchOnly() {
        Quickshell.execDetached(["bash", "-c",
            "sudo -n envycontrol --switch " + root.targetMode])
        notify("GPU mode → " + root.targetLabel,
               "Switched without reboot. The change takes effect on your next reboot.")
        Qt.quit()
    }

    function switchAndReboot() {
        notify("GPU mode → " + root.targetLabel,
               "Switched. Your system will reboot now.")
        // envycontrol needs root (sudoers NOPASSWD); reboot is passwordless via polkit
        Quickshell.execDetached(["bash", "-c",
            "sleep 1 && sudo -n envycontrol --switch " + root.targetMode + " && sleep 1 && systemctl reboot"])
        Qt.quit()
    }

    Process {
        id: queryProc
        running: true
        command: ["bash", "-c", "envycontrol --query 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                const text = this.text.trim().toLowerCase()
                if (text.includes("hybrid"))
                    root.currentMode = "hybrid"
                else
                    root.currentMode = "integrated"
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "#8a000000"
        MouseArea { anchors.fill: parent; onClicked: Qt.quit() }
    }

    Rectangle {
        id: card
        width: 540
        height: 220
        radius: 14
        color: "#f0212136"
        border { color: "#30ffffff"; width: 1 }
        anchors.centerIn: parent
        focus: true
        activeFocusOnTab: true

        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Y || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.switchAndReboot()
                event.accepted = true
            } else if (event.key === Qt.Key_S) {
                root.switchOnly()
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
                text: "Switch GPU to " + root.targetLabel + "?"
                color: "#ffffff"
                font.pixelSize: 19
                font.bold: true
            }

            Text {
                text: "Currently: " + (root.currentMode === "hybrid" ? "Hybrid (dGPU on)" : "Integrated (iGPU only)")
                color: "#ccd6ff"
                font.pixelSize: 13
                wrapMode: Text.WordWrap
                width: parent.width
            }

            Row {
                spacing: 12
                anchors.horizontalCenter: parent.horizontalCenter

                Button { text: "Switch & Reboot"; onClicked: root.switchAndReboot() }
                Button { text: "Switch only"; onClicked: root.switchOnly() }
                Button { text: "Cancel"; onClicked: Qt.quit() }
            }

            Text {
                text: "or press   y = switch + reboot    s = switch only    n = cancel"
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
