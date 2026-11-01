// Tiny stroke-icon renderer. Paths are the 24x24 SVG paths used by the Space.
import QtQuick
import QtQuick.Shapes

Item {
    id: root

    property string kind: "mic"
    property color color: "#aeb8c3"
    property real weight: 1.9

    implicitWidth: 20
    implicitHeight: 20

    readonly property var paths: {
        switch (root.kind) {
        case "speaker":
            return ["M4 9.5v5h3.5L12 18.5v-13L7.5 9.5z", "M15.5 9a4 4 0 0 1 0 6", "M18.2 6.5a7.5 7.5 0 0 1 0 11"]
        case "speaker-off":
            return ["M4 9.5v5h3.5L12 18.5v-13L7.5 9.5z", "m16 9.5 5 5m0-5-5 5"]
        case "transcript":
            return ["M5 7h14M5 12h14M5 17h9"]
        case "close":
            return ["M6 6l12 12M18 6 6 18"]
        case "mic":
            return ["M9 6.5a3 3 0 0 1 6 0v5a3 3 0 0 1-6 0z", "M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v2.5"]
        case "send":
            return ["M12 19V5.5M6 11l6-6 6 6"]
        case "chevron-down":
            return ["m6 9 6 6 6-6"]
        case "check":
            return ["M5 12.5l4.5 4.5L19 6.5"]
        case "stop":
            return []
        default:
            return []
        }
    }

    Rectangle {
        visible: root.kind === "stop"
        width: 11
        height: 11
        radius: 2.5
        color: root.color
        anchors.centerIn: parent
    }

    Item {
        anchors.centerIn: parent
        width: 24
        height: 24
        scale: root.width / 24
        visible: root.kind !== "stop"

        Repeater {
            model: root.paths
            delegate: Shape {
                width: 24
                height: 24
                antialiasing: true
                ShapePath {
                    strokeColor: root.color
                    strokeWidth: root.weight
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin
                    PathSvg {
                        path: modelData
                    }
                }
            }
        }
    }
}
