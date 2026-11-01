// DigUp media card for the Intelligence tab.
//
// Quickshell-side component: QtMultimedia stays here so IntelligenceTab.qml
// keeps only Qt Quick imports. Never autoplays: audio and video start only on a
// click. Opening a path goes through the existing DigUp helper script, never
// automatically.

import QtQuick
import QtQuick.Shapes
import QtMultimedia
import Quickshell

Item {
    id: root

    // One entry of the bridge's `media` event: { path, kind, mime, snippet,
    // match, thumbnail, loc, size, modified, media }
    property var result: ({})
    property color ink: "#e6ebf0"
    property color ink2: "#aeb8c3"
    property color muted: "#7b8794"
    property color line: "#40e6ebf0"
    property color glass: "#b31e2732"
    property color accent: "#2cc4d8"
    property string sansFamily: "sans-serif"
    property string serifFamily: "Georgia"
    property bool dark: true

    readonly property string path: root.result && root.result.path ? String(root.result.path) : ""
    readonly property string kind: root.result && root.result.kind ? String(root.result.kind) : "file"
    readonly property string mime: root.result && root.result.mime ? String(root.result.mime) : ""
    readonly property string pathName: root.path.length > 0 ? root.path.split("/").pop() : ""
    readonly property string fileUrl: root.path.length > 0 ? "file://" + encodeURI(root.path) : ""
    readonly property bool isImage: root.kind === "image" || root.kind === "screenshot"
                                     || root.mime.indexOf("image/") === 0
    readonly property bool isVideo: root.kind === "video" || root.mime.indexOf("video/") === 0
    readonly property bool isAudio: root.kind === "audio" || root.mime.indexOf("audio/") === 0
    readonly property bool hasPreview: root.isImage || root.isVideo
    readonly property string snippet: root.result && root.result.snippet ? String(root.result.snippet) : ""
    readonly property string loc: root.result && root.result.loc !== undefined && root.result.loc !== null
                                  ? String(root.result.loc) : ""
    readonly property string helper: Quickshell.env("HOME") + "/.config/hypr/custom/scripts/digup-open.sh"

    implicitHeight: card.height

    function _launch(mode) {
        if (root.path.length === 0)
            return
        Quickshell.execDetached(["bash", root.helper, mode, "--", root.path, root.kind, root.loc])
    }

    function _toggleVideo() {
        if (!root.isVideo)
            return
        if (videoPlayer.playbackState === MediaPlayer.PlayingState) {
            videoPlayer.pause()
        } else {
            videoPlayer.source = root.fileUrl
            videoPlayer.play()
        }
    }

    function _toggleAudio() {
        if (!root.isAudio)
            return
        if (audioPlayer.playbackState === MediaPlayer.PlayingState) {
            audioPlayer.pause()
        } else {
            audioPlayer.source = root.fileUrl
            audioPlayer.play()
        }
    }

    MediaPlayer {
        id: audioPlayer
        audioOutput: AudioOutput { id: audioOut; volume: 0.8 }
    }

    MediaPlayer {
        id: videoPlayer
        audioOutput: AudioOutput { id: videoOutAudio; volume: 0.8 }
    }

    Rectangle {
        id: card
        width: root.width
        height: content.implicitHeight + 20
        radius: 12
        color: root.glass
        border.width: 1
        border.color: root.line
        clip: true

        Column {
            id: content
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: 10
            }
            spacing: 8

            // Still frame: image thumbnail, or a video poster with a play overlay.
            Rectangle {
                width: parent.width
                height: root.hasPreview ? 112 : 0
                visible: root.hasPreview
                radius: 8
                color: "#0d131a"
                clip: true

                Image {
                    id: thumb
                    anchors.fill: parent
                    visible: root.isImage || (root.isVideo && root.snippet.length === 0)
                    source: root.isImage ? root.fileUrl
                                         : (root.result && root.result.thumbnail ? "file://" + encodeURI(String(root.result.thumbnail)) : "")
                    asynchronous: true
                    cache: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: 320
                }

                VideoOutput {
                    id: videoOutput
                    anchors.fill: parent
                    visible: root.isVideo && videoPlayer.playbackState !== MediaPlayer.StoppedState
                    fillMode: VideoOutput.PreserveAspectCrop
                }

                Connections {
                    target: videoPlayer
                    function onMediaStatusChanged() {
                        if (videoPlayer.mediaStatus === MediaPlayer.EndOfMedia)
                            videoPlayer.stop()
                    }
                }

                // VideoOutput must be the player's sink while this card lives.
                Component.onCompleted: videoPlayer.videoOutput = videoOutput

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 24
                    visible: root.isImage
                    color: "#660a0e13"
                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.pathName
                        color: root.ink2
                        font.family: root.sansFamily
                        font.pixelSize: 9
                        elide: Text.ElideMiddle
                        width: parent.width - 16
                    }
                }

                // Video play/pause control, no autoplay.
                Rectangle {
                    visible: root.isVideo
                    anchors.centerIn: parent
                    width: 42
                    height: 42
                    radius: 21
                    color: "#b3121922"
                    border.width: 1
                    border.color: root.line

                    Shape {
                        anchors.centerIn: parent
                        width: 12
                        height: 13
                        visible: videoPlayer.playbackState !== MediaPlayer.PlayingState
                        ShapePath {
                            strokeColor: "transparent"
                            fillColor: root.ink
                            PathSvg { path: "M1 1l10 5.5-10 5.5z" }
                        }
                    }
                    Rectangle {
                        visible: videoPlayer.playbackState === MediaPlayer.PlayingState
                        anchors.centerIn: parent
                        width: 3
                        height: 11
                        color: root.ink
                    }
                    Rectangle {
                        visible: videoPlayer.playbackState === MediaPlayer.PlayingState
                        anchors.centerIn: parent
                        anchors.horizontalCenterOffset: 6
                        width: 3
                        height: 11
                        color: root.ink
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._toggleVideo()
                    }
                }
            }

            // Header: kind dot, name, open/reveal.
            Row {
                width: parent.width
                spacing: 6

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 5
                    height: 5
                    radius: 2.5
                    color: root.isVideo ? root.accent
                           : (root.isAudio ? "#f27d93" : (root.isImage ? "#7f92cc" : root.muted))
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(40, parent.width - 96)
                    text: root.pathName
                    color: root.ink
                    font.family: root.sansFamily
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    elide: Text.ElideMiddle
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "open"
                    color: openHover.containsMouse ? root.ink : root.muted
                    font.family: root.sansFamily
                    font.pixelSize: 10
                    MouseArea {
                        id: openHover
                        anchors.fill: parent
                        anchors.margins: -4
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._launch("open")
                    }
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "reveal"
                    color: revealHover.containsMouse ? root.ink : root.muted
                    font.family: root.sansFamily
                    font.pixelSize: 10
                    MouseArea {
                        id: revealHover
                        anchors.fill: parent
                        anchors.margins: -4
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._launch("reveal")
                    }
                }
            }

            Text {
                width: parent.width
                visible: root.snippet.length > 0 || root.kind.length > 0
                text: root.snippet.length > 0 ? root.snippet : root.kind
                color: root.muted
                font.family: root.serifFamily
                font.pixelSize: 13
                lineHeight: 1.2
                lineHeightMode: Text.ProportionalHeight
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
            }

            // Inline audio transport, no autoplay.
            Rectangle {
                visible: root.isAudio
                width: playRow.implicitWidth + 20
                height: 26
                radius: 13
                color: "transparent"
                border.width: 1
                border.color: playHover.containsMouse ? "#59e6ebf0" : root.line

                Row {
                    id: playRow
                    anchors.centerIn: parent
                    spacing: 7

                    Shape {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 10
                        height: 12
                        ShapePath {
                            strokeColor: "transparent"
                            fillColor: root.ink2
                            PathSvg {
                                path: audioPlayer.playbackState === MediaPlayer.PlayingState
                                      ? "M1 1h3v10H1zM6 1h3v10H6z"
                                      : "M1 1l8 5-8 5z"
                            }
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: audioPlayer.playbackState === MediaPlayer.PlayingState ? "Pause" : "Play"
                        color: root.ink2
                        font.family: root.sansFamily
                        font.pixelSize: 10
                    }
                }

                MouseArea {
                    id: playHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root._toggleAudio()
                }
            }
        }
    }
}
