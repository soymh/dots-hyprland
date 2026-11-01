// Files staged for the next message: one chip per path, with a remove button.
// Pure Qt Quick: used by IntelligenceTab.qml so the qml6 preview stays clean.

import QtQuick

Item {
    id: root

    // [{ path, name, kind }] where kind is image | video | audio | file
    property var attachments: []
    property color ink: "#e6ebf0"
    property color ink2: "#aeb8c3"
    property color muted: "#7b8794"
    property color line: "#29e6ebf0"
    property color glass: "#b31e2732"
    property string sansFamily: "sans-serif"

    signal removeRequested(int index)

    implicitHeight: 30
    implicitWidth: 240
    clip: true

    Flickable {
        id: strip
        anchors.fill: parent
        contentWidth: chipRow.width
        contentHeight: height
        boundsBehavior: Flickable.StopAtBounds
        interactive: chipRow.width > width

        Row {
            id: chipRow
            height: strip.height
            spacing: 6

            Repeater {
                model: root.attachments

                delegate: Rectangle {
                    id: chip
                    required property var modelData
                    required property int index

                    height: 26
                    width: Math.min(chipContent.implicitWidth + 30, root.width - 4)
                    radius: 13
                    color: root.glass
                    border.width: 1
                    border.color: removeHover.containsMouse ? "#40ffffff" : root.line

                    Row {
                        id: chipContent
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 5
                            height: 5
                            radius: 2.5
                            color: root.kindColor(chip.modelData.kind)
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: String(chip.modelData.kind || "file").toUpperCase()
                            color: root.muted
                            font.family: root.sansFamily
                            font.pixelSize: 8
                            font.letterSpacing: 0.8
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, 92)
                            text: chip.modelData.name || ""
                            color: root.ink2
                            font.family: root.sansFamily
                            font.pixelSize: 11
                            elide: Text.ElideMiddle
                        }
                    }

                    Item {
                        id: removeHit
                        anchors.right: parent.right
                        anchors.rightMargin: 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22
                        height: 22

                        Text {
                            anchors.centerIn: parent
                            text: "\u00d7"
                            color: removeHover.containsMouse ? root.ink : root.muted
                            font.family: root.sansFamily
                            font.pixelSize: 14
                        }

                        MouseArea {
                            id: removeHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.removeRequested(chip.index)
                        }
                    }
                }
            }
        }
    }

    function kindColor(kind) {
        switch (String(kind)) {
        case "image": return "#7f92cc"
        case "video": return "#2cc4d8"
        case "audio": return "#f27d93"
        default: return "#7b8794"
        }
    }
}
