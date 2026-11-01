import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

// Standalone popup shown while holding SUPER+CTRL+SPACE.
// Shows a live mic spectrum (via cava pointed at the active mic source)
// plus a recording indicator. It quits itself when /tmp/whisper_live/done
// appears (written by whisper-live.sh after the transcription is committed).
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

PanelWindow {
    id: root
    visible: true
    color: "transparent"

    WlrLayershell.namespace: "qs-whisper-live"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    readonly property var activeScreen: Quickshell.screens.find(
        s => s.name === Hyprland.focusedMonitor?.name
    )
    screen: activeScreen

    anchors { top: true; bottom: true; left: true; right: true }

    property list<var> spectrum: []

    // Blocks until whisper-live.sh stop creates the done marker, then fades out.
    Process {
        running: true
        command: ["/bin/sh", "-c",
                  "while [ ! -f /tmp/whisper_live/done ]; do sleep 0.15; done"]
        onExited: exitInfo => {
            Qt.callLater(() => fadeAnim.start())
        }
    }

    SequentialAnimation {
        id: fadeAnim
        NumberAnimation { target: content; property: "opacity"; to: 0; duration: 220 }
        ScriptAction { script: Qt.quit() }
    }

    // All visible UI lives here, so opacity fade works (PanelWindow lacks it)
    Item {
        id: content
        anchors.fill: parent
        opacity: 1

        Behavior on opacity { NumberAnimation { duration: 180 } }
        NumberAnimation on opacity { from: 0; to: 1; duration: 150; running: true }

        // Dim background
        Rectangle {
            anchors.fill: parent
            color: "#66000000"
        }

        // Centered card: spectrum + status
        Rectangle {
            id: card
            width: 640
            height: 200
            radius: 14
            color: "#ea212136"
            border { color: "#30ffffff"; width: 1 }
            anchors.centerIn: parent

            Column {
                anchors.fill: parent
                anchors.margins: 24
                spacing: 12

                Text {
                    text: "whisper-live  ·  transcribing"
                    color: "#dfe8ff"
                    font.pixelSize: 18
                    font.bold: true
                }

                // Spectrum surface (cava raw output -> animated bars)
                Canvas {
                    id: spectrumCanvas
                    width: parent.width
                    height: 90

                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()

                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        var pts = root.spectrum
                        var n = pts.length
                        if (n < 2) return
                        var w = width / n
                        ctx.fillStyle = "#7fbffc"
                        for (var i = 0; i < n; ++i) {
                            var h = Math.min(height, (pts[i] / 1000) * height)
                            ctx.fillRect(i * w + w * 0.2, height - h, w * 0.6, h)
                        }
                    }
                }

                Row {
                    spacing: 8
                    Rectangle {
                        width: 10; height: 10; radius: 5
                        color: "#ff5f6b"
                        anchors.verticalCenter: parent.verticalCenter
                        SequentialAnimation on color {
                            running: true
                            loops: Animation.Infinite
                            ColorAnimation { to: "#ff8a93"; duration: 400 }
                            ColorAnimation { to: "#ff5f6b"; duration: 400 }
                        }
                    }
                    Text {
                        text: "recording mic…  release to commit"
                        color: "#bfc9ff"
                        font.pixelSize: 13
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }
    }

    // Pull cava's raw output -> spectrum (async, non-blocking)
    Process {
        id: cavaProc
        running: true

        command: ["/usr/bin/cava", "-p", "/tmp/whisper_live/cava-config.txt"]

        stdout: SplitParser {
            onRead: data => {
                var pts = data.split(";").map(p => parseFloat(p.trim())).filter(n => !isNaN(n))
                root.spectrum = pts
                spectrumCanvas.requestPaint()
            }
        }
    }

    Component.onDestruction: {
        cavaProc.running = false
    }
}