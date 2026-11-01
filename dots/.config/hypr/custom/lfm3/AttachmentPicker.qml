// In-sidebar file picker for the Intelligence composer.
// Pure Qt Quick: no FileDialog, no portal, no extra window. The sidebar stays
// focused, so it cannot be dismissed by a focus grab from another surface.

import QtQuick
import Qt.labs.folderlistmodel
import Qt.labs.platform as Platform

FocusScope {
    id: picker

    property bool open: false
    property url folder: picker.homeFolder
    property var selectedPaths: []
    property string filterKey: "all"

    property color ink: "#e6ebf0"
    property color ink2: "#aeb8c3"
    property color muted: "#7b8794"
    property color line: "#29e6ebf0"
    property color panelColor: "#1c2530"
    property color accent: "#7f92cc"
    property string sansFamily: "sans-serif"

    readonly property url homeFolder: Platform.StandardPaths.writableLocation(Platform.StandardPaths.HomeLocation)

    readonly property var imageExtensions: ["png", "jpg", "jpeg", "webp", "gif", "bmp", "avif", "heic"]
    readonly property var videoExtensions: ["mp4", "mov", "mkv", "webm", "avi", "m4v"]
    readonly property var audioExtensions: ["mp3", "wav", "flac", "ogg", "opus", "m4a", "aac"]

    readonly property var filterOptions: [
        { "key": "all", "label": "All" },
        { "key": "image", "label": "Images" },
        { "key": "video", "label": "Video" },
        { "key": "audio", "label": "Audio" }
    ]

    readonly property var activeNameFilters: {
        switch (picker.filterKey) {
        case "image": return picker.patterns(picker.imageExtensions)
        case "video": return picker.patterns(picker.videoExtensions)
        case "audio": return picker.patterns(picker.audioExtensions)
        default:
            return picker.patterns(picker.imageExtensions)
                    .concat(picker.patterns(picker.videoExtensions))
                    .concat(picker.patterns(picker.audioExtensions))
        }
    }

    readonly property string currentPath: picker.pathOf(picker.folder)
    readonly property var pathSegments: {
        var path = picker.currentPath
        var parts = path.split("/")
        var out = []
        var acc = ""
        for (var i = 0; i < parts.length; ++i) {
            if (parts[i].length === 0)
                continue
            acc += "/" + parts[i]
            out.push({ "label": parts[i], "url": picker.urlForPath(acc) })
        }
        return out
    }
    readonly property int selectedCount: picker.selectedPaths.length

    signal attachRequested(var paths)
    signal closed()

    visible: open
    z: 800

    function patterns(list) {
        var out = []
        for (var i = 0; i < list.length; ++i) {
            out.push("*." + list[i])
            out.push("*." + list[i].toUpperCase())
        }
        return out
    }

    function pathOf(url) {
        var s = String(url)
        if (s.indexOf("file://") === 0)
            s = decodeURIComponent(s.substring(7))
        return s
    }

    function urlForPath(path) {
        return "file://" + String(path).split("/").map(encodeURIComponent).join("/")
    }

    function extensionOf(path) {
        var name = String(path).split("/").pop()
        var dot = name.lastIndexOf(".")
        if (dot <= 0 || dot === name.length - 1)
            return ""
        return name.substring(dot + 1).toLowerCase()
    }

    function kindOf(path) {
        var ext = picker.extensionOf(path)
        if (picker.imageExtensions.indexOf(ext) >= 0) return "image"
        if (picker.videoExtensions.indexOf(ext) >= 0) return "video"
        if (picker.audioExtensions.indexOf(ext) >= 0) return "audio"
        return "file"
    }

    function isSupported(path) {
        return picker.kindOf(path) !== "file"
    }

    function openPicker() {
        if (picker.open)
            return
        picker.folder = picker.homeFolder
        picker.selectedPaths = []
        picker.filterKey = "all"
        picker.open = true
        picker.forceActiveFocus()
        Qt.callLater(function () { picker.forceActiveFocus() })
    }

    function dismiss() {
        if (!picker.open)
            return
        picker.open = false
        picker.closed()
    }

    function navigateTo(url) {
        picker.folder = url
        pathFlick.contentX = Math.max(0, pathRow.width - pathFlick.width)
    }

    function goUp() {
        var path = picker.currentPath.replace(/\/+$/, "")
        var index = path.lastIndexOf("/")
        if (index <= 0)
            path = "/"
        else
            path = path.substring(0, index)
        picker.navigateTo(picker.urlForPath(path))
    }

    function isSelected(path) {
        return picker.selectedPaths.indexOf(path) >= 0
    }

    function togglePath(path) {
        if (!picker.isSupported(path))
            return
        var next = picker.selectedPaths.slice()
        var index = next.indexOf(path)
        if (index >= 0)
            next.splice(index, 1)
        else
            next.push(path)
        picker.selectedPaths = next
    }

    function confirmSelection() {
        if (picker.selectedPaths.length === 0)
            return
        var paths = picker.selectedPaths.slice()
        picker.open = false
        picker.attachRequested(paths)
        picker.closed()
        Qt.callLater(function () { picker.forceActiveFocus() })
    }

    Keys.onEscapePressed: (event) => {
        event.accepted = true
        picker.dismiss()
    }

    // Dimmed page. A click outside the panel closes the picker; the panel has
    // its own accepting MouseArea so clicks inside do not reach this one.
    Rectangle {
        anchors.fill: parent
        color: "#99000000"

        MouseArea {
            anchors.fill: parent
            onClicked: picker.dismiss()
        }
    }

    Rectangle {
        id: panel
        anchors.centerIn: parent
        width: Math.min(parent.width - 24, 400)
        height: Math.min(parent.height - 32, 540)
        radius: 14
        color: picker.panelColor
        border.width: 1
        border.color: picker.line
        clip: true

        MouseArea {
            anchors.fill: parent
            onClicked: {}
        }

        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8

            Item {
                id: titleRow
                width: parent.width
                height: 24

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Attach media"
                    color: picker.ink
                    font.family: picker.sansFamily
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }

                Item {
                    id: closeButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 24
                    height: 24

                    Text {
                        anchors.centerIn: parent
                        text: "\u00d7"
                        color: closeHover.containsMouse ? picker.ink : picker.muted
                        font.family: picker.sansFamily
                        font.pixelSize: 16
                    }

                    MouseArea {
                        id: closeHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: picker.dismiss()
                    }
                }
            }

            Row {
                id: filterRow
                width: parent.width
                spacing: 4

                Repeater {
                    model: picker.filterOptions

                    delegate: Rectangle {
                        id: filterButton
                        required property var modelData

                        width: (filterRow.width - 12) / 4
                        height: 24
                        radius: 12
                        color: picker.filterKey === filterButton.modelData.key ? "#2f7f92cc" : "#12ffffff"
                        border.width: 1
                        border.color: picker.filterKey === filterButton.modelData.key ? picker.accent : "transparent"

                        Text {
                            anchors.centerIn: parent
                            text: filterButton.modelData.label
                            color: picker.filterKey === filterButton.modelData.key ? picker.ink : picker.ink2
                            font.family: picker.sansFamily
                            font.pixelSize: 10
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: picker.filterKey = filterButton.modelData.key
                        }
                    }
                }
            }

            Row {
                id: pathBar
                width: parent.width
                height: 26
                spacing: 4

                Rectangle {
                    id: upButton
                    width: 26
                    height: 26
                    radius: 7
                    color: upHover.containsMouse ? "#1affffff" : "#10ffffff"

                    Text {
                        anchors.centerIn: parent
                        text: "\u2191"
                        color: upHover.containsMouse ? picker.ink : picker.ink2
                        font.family: picker.sansFamily
                        font.pixelSize: 13
                    }

                    MouseArea {
                        id: upHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: picker.goUp()
                    }
                }

                Rectangle {
                    id: pathField
                    width: pathBar.width - upButton.width - 4
                    height: 26
                    radius: 7
                    color: "#10ffffff"
                    clip: true

                    Flickable {
                        id: pathFlick
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        contentWidth: pathRow.width
                        contentHeight: pathRow.height
                        boundsBehavior: Flickable.StopAtBounds
                        interactive: pathRow.width > width

                        Row {
                            id: pathRow
                            height: pathFlick.height
                            spacing: 2

                            Text {
                                id: homeCrumb
                                anchors.verticalCenter: parent.verticalCenter
                                text: "~"
                                color: homeHover.containsMouse ? picker.ink : picker.muted
                                font.family: picker.sansFamily
                                font.pixelSize: 10

                                MouseArea {
                                    id: homeHover
                                    anchors.fill: parent
                                    anchors.margins: -3
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: picker.navigateTo(picker.homeFolder)
                                }
                            }

                            Repeater {
                                model: picker.pathSegments

                                delegate: Row {
                                    id: crumb
                                    required property var modelData

                                    height: pathRow.height

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "/"
                                        color: picker.muted
                                        font.family: picker.sansFamily
                                        font.pixelSize: 10
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: crumb.modelData.label
                                        color: crumbHover.containsMouse ? picker.ink : picker.ink2
                                        font.family: picker.sansFamily
                                        font.pixelSize: 10

                                        MouseArea {
                                            id: crumbHover
                                            anchors.fill: parent
                                            anchors.margins: -3
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: picker.navigateTo(crumb.modelData.url)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                id: listFrame
                width: parent.width
                height: parent.height - titleRow.height - filterRow.height - pathBar.height
                        - footer.height - parent.spacing * 4
                radius: 9
                color: "#0d000000"
                border.width: 1
                border.color: "#0fffffff"
                clip: true

                FolderListModel {
                    id: folderModel
                    folder: picker.folder
                    showDirs: true
                    showDirsFirst: true
                    showFiles: true
                    showHidden: false
                    showDotAndDotDot: false
                    sortField: FolderListModel.Name
                    nameFilters: picker.activeNameFilters
                }

                ListView {
                    id: fileList
                    anchors.fill: parent
                    anchors.margins: 4
                    clip: true
                    model: folderModel
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Rectangle {
                        id: fileRow
                        required property string fileName
                        required property string filePath
                        required property bool fileIsDir
                        required property int index

                        readonly property url entryUrl: picker.urlForPath(fileRow.filePath)
                        readonly property bool selected: !fileRow.fileIsDir && picker.isSelected(fileRow.filePath)
                        readonly property string kind: picker.kindOf(fileRow.filePath)

                        width: fileList.width
                        height: 40
                        radius: 7
                        color: fileRow.selected ? "#327f92cc" : (rowHover.containsMouse ? "#12ffffff" : "transparent")

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: 5
                            anchors.right: parent.right
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 8

                            Rectangle {
                                id: thumbFrame
                                anchors.verticalCenter: parent.verticalCenter
                                width: 30
                                height: 30
                                radius: 6
                                color: "#1a2430"
                                clip: true

                                Image {
                                    id: thumb
                                    anchors.fill: parent
                                    source: (!fileRow.fileIsDir && fileRow.kind === "image") ? fileRow.entryUrl : ""
                                    asynchronous: true
                                    cache: false
                                    sourceSize.width: 60
                                    sourceSize.height: 60
                                    fillMode: Image.PreserveAspectCrop
                                    visible: status === Image.Ready
                                }

                                Item {
                                    anchors.fill: parent
                                    visible: fileRow.fileIsDir

                                    Rectangle {
                                        anchors.centerIn: parent
                                        anchors.verticalCenterOffset: 2
                                        width: 17
                                        height: 11
                                        radius: 2
                                        color: "#8fa0b5"
                                    }

                                    Rectangle {
                                        anchors.centerIn: parent
                                        anchors.verticalCenterOffset: -4
                                        anchors.horizontalCenterOffset: -3
                                        width: 9
                                        height: 6
                                        radius: 2
                                        color: "#8fa0b5"
                                    }
                                }

                                Text {
                                    anchors.centerIn: parent
                                    visible: !fileRow.fileIsDir && thumb.status !== Image.Ready
                                    text: fileRow.kind === "image" ? "IMG"
                                          : fileRow.kind === "video" ? "VID"
                                          : fileRow.kind === "audio" ? "AUD" : "FILE"
                                    color: picker.muted
                                    font.family: picker.sansFamily
                                    font.pixelSize: 7
                                    font.letterSpacing: 0.5
                                }
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - thumbFrame.width - checkFrame.width - parent.spacing * 2
                                spacing: 1

                                Text {
                                    width: parent.width
                                    text: fileRow.fileName
                                    color: fileRow.selected ? picker.ink : picker.ink2
                                    font.family: picker.sansFamily
                                    font.pixelSize: 11
                                    elide: Text.ElideMiddle
                                }

                                Text {
                                    text: fileRow.fileIsDir ? "Folder"
                                          : fileRow.kind === "image" ? "Image"
                                          : fileRow.kind === "video" ? "Video"
                                          : fileRow.kind === "audio" ? "Audio" : "File"
                                    color: picker.muted
                                    font.family: picker.sansFamily
                                    font.pixelSize: 8
                                }
                            }

                            Item {
                                id: checkFrame
                                anchors.verticalCenter: parent.verticalCenter
                                width: 18
                                height: 18

                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 14
                                    height: 14
                                    radius: 4
                                    color: fileRow.selected ? picker.accent : "transparent"
                                    border.width: 1
                                    border.color: fileRow.selected ? picker.accent : "#40ffffff"

                                    Text {
                                        anchors.centerIn: parent
                                        visible: fileRow.selected
                                        text: "\u2713"
                                        color: "#121922"
                                        font.family: picker.sansFamily
                                        font.pixelSize: 9
                                        font.weight: Font.Bold
                                    }
                                }
                            }
                        }

                        MouseArea {
                            id: rowHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (fileRow.fileIsDir)
                                    picker.navigateTo(fileRow.entryUrl)
                                else
                                    picker.togglePath(fileRow.filePath)
                            }
                            onDoubleClicked: {
                                if (fileRow.fileIsDir)
                                    picker.navigateTo(fileRow.entryUrl)
                                else {
                                    if (!fileRow.selected)
                                        picker.togglePath(fileRow.filePath)
                                    picker.confirmSelection()
                                }
                            }
                        }
                    }
                }

                Text {
                    anchors.centerIn: parent
                    visible: folderModel.count === 0
                    text: "No matching files here"
                    color: picker.muted
                    font.family: picker.sansFamily
                    font.pixelSize: 10
                }
            }

            Item {
                id: footer
                width: parent.width
                height: 30

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: picker.selectedCount === 0 ? "Select one or more files"
                                                      : picker.selectedCount + (picker.selectedCount === 1 ? " file selected" : " files selected")
                    color: picker.muted
                    font.family: picker.sansFamily
                    font.pixelSize: 10
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Rectangle {
                        id: cancelButton
                        width: 62
                        height: 28
                        radius: 14
                        color: cancelHover.containsMouse ? "#1affffff" : "#10ffffff"

                        Text {
                            anchors.centerIn: parent
                            text: "Cancel"
                            color: picker.ink2
                            font.family: picker.sansFamily
                            font.pixelSize: 10
                        }

                        MouseArea {
                            id: cancelHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: picker.dismiss()
                        }
                    }

                    Rectangle {
                        id: attachButton
                        width: 78
                        height: 28
                        radius: 14
                        color: picker.selectedCount === 0 ? "#1affffff" : picker.accent
                        opacity: picker.selectedCount === 0 ? 0.55 : 1

                        Text {
                            anchors.centerIn: parent
                            text: picker.selectedCount === 0 ? "Attach" : "Attach " + picker.selectedCount
                            color: picker.selectedCount === 0 ? picker.muted : "#121922"
                            font.family: picker.sansFamily
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: picker.selectedCount > 0
                            cursorShape: Qt.PointingHandCursor
                            onClicked: picker.confirmSelection()
                        }
                    }
                }
            }
        }
    }
}
