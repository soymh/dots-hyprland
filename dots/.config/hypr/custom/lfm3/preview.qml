// Intelligence tab preview. Plain Qt Quick only: no Quickshell imports.
//
//   qml6 qml/preview.qml              -> 400x900, the real sidebar tab size
//   qml6 qml/preview.qml --large      -> 440x820 inside a mock sidebar panel
//
// After 1.5 s it grabs only this QML item to /tmp/lfm3-qml-preview.png and
// quits. No desktop capture tool is involved.

import QtQuick
import QtQuick.Window

Window {
    id: win

    readonly property bool large: Qt.application.arguments.join(" ").indexOf("large") >= 0

    width: large ? 1160 : 400
    height: large ? 880 : 900
    visible: true
    color: "#0a0e13"
    title: "LFM3-Omni sidebar tab"

    // Desktop backdrop, only visible in the large preview.
    Rectangle {
        anchors.fill: parent
        visible: win.large
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#0a0f16" }
            GradientStop { position: 1.0; color: "#121b26" }
        }
    }

    // Mock sidebar shell, only visible in the large preview.
    Rectangle {
        visible: win.large
        anchors.centerIn: parent
        width: stage.width + 20
        height: stage.height + 20
        radius: 14
        color: "#161c25"
        border.width: 1
        border.color: "#26ffffff"

        Rectangle {
            anchors.fill: parent
            anchors.margins: 9
            radius: 10
            color: "#121922"
            opacity: 0.35
        }
    }

    Item {
        id: stage
        width: win.large ? 440 : 400
        height: win.large ? 820 : 900
        anchors.centerIn: parent
        clip: true

        IntelligenceTab {
            id: tab
            anchors.fill: parent
        }
    }

    Timer {
        interval: 1500
        running: true
        onTriggered: {
            stage.grabToImage(function (image) {
                var ok = image.saveToFile("/tmp/lfm3-qml-preview.png")
                console.log("LFM3 preview saved:", ok ? "/tmp/lfm3-qml-preview.png" : "failed")
                Qt.quit()
            }, Qt.size(stage.width, stage.height))
        }
    }

    Component.onCompleted: tab.focusComposer()
}
