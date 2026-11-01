//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

// DigUp semantic file search popup (Linux port of the Mac search panel).
// Launched via custom/scripts/digup-search.sh or the /digup overview action.
// Search itself runs in digup-linux (JSON over stdout); open/reveal goes
// through custom/scripts/digup-open.sh.
PanelWindow {
    id: root
    visible: true
    color: "transparent"

    WlrLayershell.namespace: "qs-digup-search"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    readonly property string home: Quickshell.env("HOME") || ""

    readonly property var activeScreen: Quickshell.screens.find(
        s => s.name === Hyprland.focusedMonitor?.name
    )
    screen: activeScreen

    anchors { top: true; bottom: true; left: true; right: true }

    property int currentIndex: -1
    property string statusText: "Describe what you're looking for…"
    property var currentHit: null

    function humanSize(bytes) {
        if (bytes < 1024) return bytes + " B"
        if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KB"
        if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + " MB"
        return (bytes / 1073741824).toFixed(1) + " GB"
    }

    function clock(secs) {
        const t = Math.floor(secs)
        if (t >= 3600) return Math.floor(t / 3600) + ":" + String(Math.floor(t / 60) % 60).padStart(2, "0") + ":" + String(t % 60).padStart(2, "0")
        return Math.floor(t / 60) + ":" + String(t % 60).padStart(2, "0")
    }

    function matchReason(h) {
        if (!h) return ""
        if (h.segment === "page" || h.segment === "page_image") return "Matches page " + Math.round(h.loc)
        if (h.segment === "audio") return "Matches the sound at " + clock(h.loc)
        if (h.segment === "frame") return "Matches the frame at " + clock(h.loc)
        if (h.segment === "ocr") return "Matches text in the image"
        if (h.segment === "chunk") return "Matches passage " + Math.round(h.loc)
        if (h.segment === "lines" || h.segment === "cells") {
            const span = "lines " + Math.round(h.loc) + "–" + Math.round(h.loc_end || h.loc)
            return (h.focus ? "Opens at line " + Math.round(h.focus) + " · " : "Matches ") + span
        }
        return "Matches the image"
    }

    function metaLine(h) {
        if (!h) return ""
        const kind = { screenshot: "Screenshot", image: "Image", pdf: "PDF", doc: "Document", audio: "Audio", video: "Video", code: "Code" }[h.kind] || h.kind
        const date = new Date(h.modified * 1000)
        const ds = date.toLocaleDateString(Qt.locale(), "MMM d, yyyy")
        let extra = ""
        if ((h.kind === "audio" || h.kind === "video") && h.info && h.info.duration) extra = " · " + clock(h.info.duration)
        if (h.kind === "pdf" && h.info && h.info.pages) extra = " · " + h.info.pages + " pages"
        return kind + " · " + ds + " · " + humanSize(h.size) + extra
    }

    function fileName(path) {
        const i = Math.max(path.lastIndexOf("/"), 0)
        return path.slice(i === 0 ? 1 : i + 1)
    }

    function dirName(path) {
        const i = path.lastIndexOf("/")
        let d = i > 0 ? path.slice(0, i) : path
        return d.replace(/^\/home\/[^/]+/, "~")
    }

    function openCurrent(reveal) {
        const h = root.currentHit
        if (!h) return
        Quickshell.execDetached([
            root.home + "/.config/hypr/custom/scripts/digup-open.sh",
            reveal ? "reveal" : "open", "--",
            h.path, h.kind, (h.loc === null || h.loc === undefined) ? "" : String(h.loc),
            (h.focus === null || h.focus === undefined) ? "" : String(Math.round(h.focus))
        ])
        if (!reveal) Qt.quit()
    }

    // Initial query from the /digup bridge (written to tmpfile by the launcher).
    Process {
        id: initProc
        running: true
        command: ["bash", "-c", "cat /tmp/digup-query 2>/dev/null; rm -f /tmp/digup-query"]
        stdout: StdioCollector {
            onStreamFinished: {
                const q = this.text.trim()
                if (q !== "") {
                    searchInput.text = q
                    root.runSearch()
                }
            }
        }
    }

    Timer {
        id: debounce
        interval: 200
        onTriggered: root.runSearch()
    }

    property int querySeq: 0
    property string lastSearchError: ""

    function runSearch() {
        const q = searchInput.text.trim()
        if (q === "") {
            resultsModel.clear()
            root.currentIndex = -1
            root.currentHit = null
            root.statusText = "Describe what you're looking for…"
            return
        }
        root.querySeq += 1
        root.statusText = root.querySeq <= 1 ? "Starting query engine…" : "Searching…"
        root.lastSearchError = ""
        stallTimer.restart()
        // One persistent query-service process (no spawn-per-keystroke, no GPU leak).
        querySvc.write(JSON.stringify({ id: root.querySeq, query: q, limit: 12 }) + "\n")
    }

    function onReply(line) {
        let msg = null
        try { msg = JSON.parse(line) } catch (e) { return }
        if (!msg || msg.id !== root.querySeq) return  // stale reply
        stallTimer.stop()
        if (!msg.ok) {
            resultsModel.clear()
            root.currentIndex = -1
            root.currentHit = null
            root.statusText = "Search failed: " + (msg.error || "unknown error").slice(0, 160)
            return
        }
        const hits = msg.hits || []
        resultsModel.clear()
        const groups = {}
        for (const h of hits) {
            const g = { video: "VIDEO", image: "IMAGES", screenshot: "IMAGES", pdf: "PDFS", doc: "DOCUMENTS", audio: "AUDIO", code: "CODE" }[h.kind] || "FILES"
            if (!groups[g]) { groups[g] = true; resultsModel.append({ isHeader: true, header: g }) }
            resultsModel.append({ isHeader: false, hit: h })
        }
        if (hits.length > 0) {
            root.currentIndex = 1  // first real row (0 is a header)
            root.currentHit = hits[0]
            root.statusText = hits.length + (hits.length === 1 ? " result" : " results")
        } else {
            root.currentIndex = -1
            root.currentHit = null
            root.statusText = "No good matches"
        }
        root.fixSelection()
    }

    Timer {
        id: stallTimer
        interval: 25000
        onTriggered: {
            if (root.statusText === "Searching…" || root.statusText === "Starting query engine…")
                root.statusText = "Query service stalled — close and reopen the popup"
        }
    }

    Process {
        id: querySvc
        running: true
        // Absolute path: Quickshell's PATH has no ~/.local/bin.
        command: [root.home + "/.local/bin/digup-linux", "query-service"]
        stdout: SplitParser {
            onRead: data => root.onReply(data)
        }
        stderr: StdioCollector {
            onStreamFinished: {
                const tail = this.text.trim().split("\n").pop().slice(0, 160)
                if (tail !== "") root.lastSearchError = tail
            }
        }
    }

    function fixSelection() {
        if (root.currentIndex < 0 || resultsModel.count === 0) return
        if (resultsModel.get(root.currentIndex).isHeader) {
            root.moveSelection(1)
        }
    }

    function moveSelection(delta) {
        if (resultsModel.count === 0) return
        let i = root.currentIndex + delta
        while (i >= 0 && i < resultsModel.count && resultsModel.get(i).isHeader) i += delta
        if (i < 0 || i >= resultsModel.count) return
        root.currentIndex = i
        root.currentHit = resultsModel.get(i).hit
        resultList.positionViewAtIndex(i, ListView.Contain)
    }

    Rectangle {
        anchors.fill: parent
        color: "#80000000"

        MouseArea {
            anchors.fill: parent
            // Only dismiss on clicks OUTSIDE the card; the card swallows its own.
            onClicked: (mouse) => {
                const cx = (parent.width - card.width) / 2
                const cy = (parent.height - card.height) / 2
                if (mouse.x < cx || mouse.x > cx + card.width
                        || mouse.y < cy || mouse.y > cy + card.height)
                    Qt.quit()
            }
        }
    }

    Rectangle {
        id: card
        width: 920
        height: 600
        radius: 14
        color: "#e63c3c40"
        border { color: "#40ffffff"; width: 1 }
        anchors.centerIn: parent

        // Swallow clicks on empty card areas so they never reach the dim layer.
        MouseArea { anchors.fill: parent }

        Column {
            anchors.fill: parent
            anchors.margins: 0
            spacing: 0

            // Search field
            Row {
                width: parent.width
                height: 64
                spacing: 8
                leftPadding: 20
                rightPadding: 20
                Text {
                    text: "⌕"
                    color: "#e0a050"
                    font.pixelSize: 22
                    anchors.verticalCenter: parent.verticalCenter
                }
                TextField {
                    id: searchInput
                    width: parent.width - 68
                    height: parent.height
                    placeholderText: "Describe what you're looking for…"
                    color: "#ffffff"
                    placeholderTextColor: "#80ffffff"
                    font.pixelSize: 20
                    background: null
                    verticalAlignment: TextInput.AlignVCenter
                    onTextChanged: debounce.restart()
                    Keys.onPressed: (event) => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            if (event.modifiers & Qt.ControlModifier) root.openCurrent(true)
                            else root.openCurrent(false)
                        } else if (event.key === Qt.Key_Escape) {
                            Qt.quit()
                        } else if (event.key === Qt.Key_Down) {
                            root.moveSelection(1)
                        } else if (event.key === Qt.Key_Up) {
                            root.moveSelection(-1)
                        }
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: "#20ffffff" }

            // Results + detail
            Row {
                width: parent.width
                height: parent.height - 64 - 36
                spacing: 0

                ListView {
                    id: resultList
                    width: 400
                    height: parent.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    model: ListModel { id: resultsModel }
                    delegate: Rectangle {
                        width: 400
                        height: model.isHeader ? 28 : 56
                        color: (index === root.currentIndex) ? "#305080c0" : "transparent"
                        Text {
                            visible: model.isHeader
                            anchors.fill: parent
                            anchors.leftMargin: 20
                            verticalAlignment: Text.AlignVCenter
                            text: model.isHeader ? model.header : ""
                            color: "#90ffffff"
                            font.pixelSize: 12
                            font.bold: true
                        }
                        Column {
                            visible: !model.isHeader
                            anchors.fill: parent
                            anchors.leftMargin: 20
                            anchors.rightMargin: 12
                            anchors.topMargin: 6
                            spacing: 2
                            Text {
                                width: parent.width
                                elide: Text.ElideRight
                                text: model.isHeader ? "" : root.fileName(model.hit.path)
                                color: "#ffffff"
                                font.pixelSize: 15
                                font.bold: index === root.currentIndex
                            }
                            Text {
                                width: parent.width
                                elide: Text.ElideRight
                                text: model.isHeader ? "" : root.dirName(model.hit.path)
                                color: "#90ffffff"
                                font.pixelSize: 12
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: !model.isHeader
                            onClicked: {
                                root.currentIndex = index
                                root.currentHit = model.hit
                            }
                            onDoubleClicked: root.openCurrent(false)
                        }
                    }
                }

                Rectangle { width: 1; height: parent.height; color: "#20ffffff" }

                // Detail pane
                Flickable {
                    width: parent.width - 401
                    height: parent.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    contentHeight: detailCol.height
                    Column {
                        id: detailCol
                        width: parent.width
                        spacing: 8
                        padding: 20
                        Image {
                            visible: root.currentHit && (root.currentHit.kind === "image" || root.currentHit.kind === "screenshot")
                            width: parent.width - 40
                            height: 260
                            fillMode: Image.PreserveAspectFit
                            source: root.currentHit ? "file://" + root.currentHit.path : ""
                            asynchronous: true
                        }
                        Text {
                            width: parent.width - 40
                            wrapMode: Text.Wrap
                            text: root.currentHit ? root.fileName(root.currentHit.path) : ""
                            color: "#ffffff"
                            font.pixelSize: 18
                            font.bold: true
                        }
                        Text {
                            width: parent.width - 40
                            wrapMode: Text.Wrap
                            text: root.currentHit ? root.dirName(root.currentHit.path) : ""
                            color: "#90ffffff"
                            font.pixelSize: 13
                        }
                        Text {
                            width: parent.width - 40
                            wrapMode: Text.Wrap
                            text: root.currentHit ? root.metaLine(root.currentHit) : ""
                            color: "#90ffffff"
                            font.pixelSize: 13
                        }
                        Text {
                            width: parent.width - 40
                            wrapMode: Text.Wrap
                            text: root.currentHit ? "⌕ " + root.matchReason(root.currentHit) : ""
                            color: "#e0a050"
                            font.pixelSize: 14
                        }
                        Text {
                            width: parent.width - 40
                            wrapMode: Text.Wrap
                            text: (root.currentHit && root.currentHit.excerpt) ? root.currentHit.excerpt : ""
                            color: "#c0ffffff"
                            font.pixelSize: 13
                        }
                        Row {
                            spacing: 10
                            Button {
                                text: "Open"
                                enabled: root.currentHit !== null
                                onClicked: root.openCurrent(false)
                            }
                            Button {
                                text: "Reveal"
                                enabled: root.currentHit !== null
                                onClicked: root.openCurrent(true)
                            }
                        }
                    }
                }
            }

            // Status bar
            Rectangle {
                width: parent.width
                height: 36
                radius: 14
                color: "transparent"
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.statusText
                    color: "#90ffffff"
                    font.pixelSize: 12
                }
                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 20
                    anchors.verticalCenter: parent.verticalCenter
                    text: "↵ Open · Ctrl+↵ Reveal · Esc Close"
                    color: "#60ffffff"
                    font.pixelSize: 12
                }
            }
        }
    }

    Component.onCompleted: {
        Qt.callLater(() => { searchInput.forceActiveFocus() })
    }
}
