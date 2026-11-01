// LFM3-Omni Intelligence tab: replacement content for the ii sidebar's
// existing Intelligence page. No extra tab, no WebEngine.
//
// Native Qt Quick only: no network, no microphone. The orb is a ShaderEffect
// running the Space's liquid shader (see Orb.qml and shaders/).
//
// Designed for a narrow sidebar page: about 380-440 px wide, 800-1000 px tall.
// The sidebar owns the tab bar; this file only draws the page content.

import QtQuick
import QtQuick.Shapes

Item {
    id: root

    // ------------------------------------------------------------------
    // Integration surface
    // ------------------------------------------------------------------
    property string status: "Ready"            // Ready | Listening | Thinking | Speaking | Loading | Not loaded
    property string replyText: "You're welcome! If you need anything else, just let me know."
    property string userText: "thanks!"
    property string metrics: "First word in 0.61 s, voice in 0.91 s"
    property var toolEvents: []                // [{ name, status: "done"|"running"|"failed", summary }]
    property var turns: [
        { "role": "user", "text": "thanks!", "at": "9:41 PM" },
        { "role": "assistant", "text": "You're welcome! If you need anything else, just let me know.", "at": "9:41 PM" }
    ]
    property bool fakeMode: true               // preview data until the bridge is wired
    property bool dark: true
    property bool transcriptOpen: false
    property bool voiceOn: true
    property string modelName: "LFM3-Omni"

    // Rich assistant reply and DigUp media cards. Both components are optional:
    // the Quickshell page (IntelligencePage.qml) injects its rich renderer and
    // media card, while the plain qml6 preview leaves them null and falls back
    // to Qt Quick only rendering.
    property Component richReplyComponent: null
    property Component mediaPreviewComponent: null

    // Files staged for the next message: [{ path, name, kind }]
    property var attachments: []
    readonly property int maxAttachments: 8
    readonly property bool attachmentPickerOpen: attachmentPicker.open
    property bool dropActive: false

    readonly property var supportedAttachmentExtensions: [
        "png", "jpg", "jpeg", "webp", "gif", "bmp", "avif", "heic",
        "mp4", "mov", "mkv", "webm", "avi", "m4v",
        "mp3", "wav", "flac", "ogg", "opus", "m4a", "aac"
    ]

    // DigUp previews for the current reply, fed by the bridge `media` event.
    property var mediaResults: []
    property string mediaQuery: ""

    // Model selector. The bridge fills `models` from the llama-server router
    // (entries discovered under ~/.models/hub); one model is loaded at a time.
    property var models: [
        { "id": "lfm3-omni-2b-q4km", "name": "LFM3-Omni-2B", "size": "Q4_K_M - 1.5 GB", "loaded": true },
        { "id": "lfm3-audio-2b-q8_0", "name": "LFM3-Audio-2B", "size": "Q8_0 - 2.3 GB", "loaded": false },
        { "id": "gemma4-e4b", "name": "Gemma4-E4B", "size": "Q4_K_M - 2.8 GB", "loaded": false }
    ]
    property string currentModel: "lfm3-omni-2b-q4km"
    property bool modelMenuOpen: false
    property real modelMenuX: 12
    property real modelMenuY: 44
    readonly property real modelMenuWidth: Math.min(320, root.width - 24)

    // Integrators may lower the stage opacity so the sidebar shows through.
    property color stageColor: "#f2121922"
    property real contentPadding: 16

    signal submitText(string text, var attachments)
    signal startListening()
    signal stopListening()
    signal cancel()
    signal newConversation()
    signal selectModel(string id)
    signal unloadModel(string id)

    // ------------------------------------------------------------------
    // Derived state
    // ------------------------------------------------------------------
    readonly property string stateKey: {
        var s = String(root.status).toLowerCase()
        if (s === "listening") return "listening"
        if (s === "thinking") return "thinking"
        if (s === "speaking") return "speaking"
        if (s === "loading") return "loading"
        if (s === "not loaded" || s === "failed") return "failed"
        return "idle"
    }
    readonly property bool busy: stateKey === "listening" || stateKey === "thinking" || stateKey === "speaking"
    // The fake flow drives `listening`; an integrator may only set `status`.
    readonly property bool isListening: listening || stateKey === "listening"
    readonly property bool inputActive: input.activeFocus
    readonly property bool hasConversation: userText.length > 0 || replyText.length > 0
    readonly property int turnCount: turns.filter(function (t) { return t.role === "assistant" }).length
    readonly property bool hasAttachments: root.attachments.length > 0
    readonly property bool hasMedia: root.mediaResults.length > 0
    // Height budget for the scrolling conversation, measured from the body top.
    readonly property real stageTop: Math.max(10, body.height * 0.115)
    readonly property real convoMaxHeight: Math.max(96, body.height - root.stageTop - 208 - 10)
    readonly property bool stickToEnd: root._stickToEnd
    property bool _stickToEnd: true

    readonly property int modelCount: root.models ? root.models.length : 0
    readonly property var currentModelInfo: {
        var list = root.models || []
        for (var i = 0; i < list.length; ++i) {
            if (list[i].id === root.currentModel)
                return list[i]
        }
        return null
    }
    readonly property string currentModelName: root.currentModelInfo ? String(root.currentModelInfo.name) : root.currentModel
    readonly property bool currentModelLoaded: root.currentModelInfo ? root.currentModelInfo.loaded === true : false
    readonly property string modelPillLabel: root.currentModelName.length > 0
        ? root.currentModelName
        : (root.modelCount > 0 ? "No model loaded" : "Choose a model")

    readonly property color ink: "#e6ebf0"
    readonly property color ink2: "#aeb8c3"
    readonly property color muted: "#7b8794"
    readonly property color line: "#14e6ebf0"
    readonly property color line2: "#29e6ebf0"
    readonly property color panel: "#17202a"
    readonly property color glass: "#b31e2732"
    readonly property color idleColor: "#7f92cc"
    readonly property color listenColor: "#2cc4d8"
    readonly property color thinkColor: "#a3acba"
    readonly property color speakColor: "#f27d93"
    readonly property color loadedColor: "#6fd0a3"

    readonly property color stateColor: {
        switch (root.stateKey) {
        case "listening": return root.listenColor
        case "thinking": return root.thinkColor
        case "speaking": return root.speakColor
        case "failed": return root.thinkColor
        default: return root.idleColor
        }
    }

    readonly property string serifFamily: serifFont.status === FontLoader.Ready ? serifFont.name : "Georgia"
    readonly property string sansFamily: sansFont.status === FontLoader.Ready ? sansFont.name : "sans-serif"

    property real audioLevel: 0
    property bool listening: false
    property string _pendingReply: ""
    property int _replyIndex: 0

    implicitWidth: 400
    implicitHeight: 900

    function focusComposer() {
        input.forceActiveFocus()
        // A request made before the window is active is dropped; retry once on
        // the next event loop pass so it lands after activation.
        Qt.callLater(() => {
            if (!root.inputActive)
                input.forceActiveFocus()
        })
    }

    // Handy for integrations and for demo scripts.
    function setDraft(text) {
        input.text = text
        input.cursorPosition = input.text.length
        input.forceActiveFocus()
    }

    function submitDraft() {
        root._submit()
    }

    // ------------------------------------------------------------------
    // Attachments
    // ------------------------------------------------------------------
    function attachmentKind(path) {
        var ext = String(path).split(".").pop().toLowerCase()
        if (["png", "jpg", "jpeg", "webp", "gif", "bmp", "avif", "heic"].indexOf(ext) >= 0)
            return "image"
        if (["mp4", "mov", "mkv", "webm", "avi", "m4v"].indexOf(ext) >= 0)
            return "video"
        if (["mp3", "wav", "flac", "ogg", "opus", "m4a", "aac"].indexOf(ext) >= 0)
            return "audio"
        return "file"
    }

    function attachmentPath(url) {
        var s = String(url)
        if (s.indexOf("file://") === 0)
            s = decodeURIComponent(s.substring(7))
        return s
    }

    function addAttachment(url) {
        var path = root.attachmentPath(url)
        if (path.length === 0)
            return false
        for (var i = 0; i < root.attachments.length; ++i) {
            if (root.attachments[i].path === path)
                return true
        }
        if (root.attachments.length >= root.maxAttachments)
            return false
        root.attachments = root.attachments.concat([{
            "path": path,
            "name": path.split("/").pop(),
            "kind": root.attachmentKind(path)
        }])
        return true
    }

    function removeAttachment(index) {
        if (index < 0 || index >= root.attachments.length)
            return
        var next = root.attachments.slice()
        next.splice(index, 1)
        root.attachments = next
    }

    function clearAttachments() {
        if (root.attachments.length > 0)
            root.attachments = []
    }

    function attachmentPaths() {
        return root.attachments.map(function (item) { return item.path })
    }

    function attachmentExtension(path) {
        var name = String(path).split("/").pop()
        var dot = name.lastIndexOf(".")
        if (dot <= 0 || dot === name.length - 1)
            return ""
        return name.substring(dot + 1).toLowerCase()
    }

    function isSupportedAttachment(path) {
        return root.supportedAttachmentExtensions.indexOf(root.attachmentExtension(path)) >= 0
    }

    // Adds every supported file URL from a drop. Returns how many were staged.
    function addDroppedUrls(urls) {
        var added = 0
        var list = urls || []
        for (var i = 0; i < list.length; ++i) {
            var url = String(list[i])
            if (url.indexOf("file://") !== 0)
                continue
            if (!root.isSupportedAttachment(url))
                continue
            if (root.addAttachment(url))
                ++added
        }
        return added
    }

    function openAttachmentPicker() {
        root.modelMenuOpen = false
        root.transcriptOpen = false
        attachmentPicker.openPicker()
    }

    function closeAttachmentPicker() {
        attachmentPicker.dismiss()
    }

    function clearMedia() {
        root.mediaQuery = ""
        if (root.mediaResults.length > 0)
            root.mediaResults = []
    }

    // ------------------------------------------------------------------
    // Conversation scrolling
    // ------------------------------------------------------------------
    function scrollConversation(delta) {
        if (!scroller)
            return
        var maxY = Math.max(0, scroller.contentHeight - scroller.height)
        scroller.contentY = Math.max(0, Math.min(maxY, scroller.contentY + delta))
        root._stickToEnd = scroller.contentY >= maxY - 8
    }

    function scrollToEnd() {
        if (!scroller)
            return
        var maxY = Math.max(0, scroller.contentHeight - scroller.height)
        scroller.contentY = maxY
        root._stickToEnd = true
    }

    function openModelMenu() {
        var origin = modelPill.mapToItem(root, 0, 0)
        root.modelMenuX = Math.max(12, Math.min(origin.x, root.width - root.modelMenuWidth - 12))
        root.modelMenuY = origin.y + modelPill.height + 6
        root.modelMenuOpen = true
    }

    function toggleModelMenu() {
        if (root.modelMenuOpen)
            root.modelMenuOpen = false
        else
            root.openModelMenu()
    }

    function chooseModel(id) {
        root.currentModel = id
        root.modelMenuOpen = false
        root.selectModel(id)
        Qt.callLater(() => input.forceActiveFocus())
    }

    function unloadCurrentModel() {
        if (!root.currentModel || !root.currentModelLoaded)
            return
        var id = root.currentModel
        root.modelMenuOpen = false
        root.unloadModel(id)
        Qt.callLater(() => input.forceActiveFocus())
    }

    function _nowLabel() {
        var d = new Date()
        var h = d.getHours()
        var m = d.getMinutes()
        var suffix = h >= 12 ? "PM" : "AM"
        h = h % 12
        if (h === 0) h = 12
        return h + ":" + (m < 10 ? "0" + m : m) + " " + suffix
    }

    function _metricsHtml() {
        var s = String(root.metrics)
        if (s.length === 0) return ""
        return s.replace(/(\d+(?:\.\d+)?\s*s)/g, '<font color="' + root.ink2 + '">$1</font>')
    }

    function _addTurn(role, text) {
        root.turns = root.turns.concat([{ "role": role, "text": text, "at": _nowLabel() }])
    }

    function _fakeReplyFor(text) {
        var t = text.toLowerCase()
        if (t.indexOf("time") >= 0)
            return "It is 9:41 PM here. The clock is local, and nothing leaves this machine."
        if (t.indexOf("hello") >= 0 || t.indexOf("hi") >= 0)
            return "Hello. Hold Space and talk, or type below. Both work offline."
        if (t.indexOf("who") >= 0 || t.indexOf("you") >= 0)
            return "I am LFM3-Omni running locally, next to your desktop, not in a browser."
        var replies = [
            "I'm running on this machine. No network, no account, just the model.",
            "That works. The first word lands in about half a second, voice shortly after.",
            "Got it. Ask me anything else, or hold Space and talk."
        ]
        var reply = replies[root._replyIndex % replies.length]
        root._replyIndex += 1
        return reply
    }

    // ------------------------------------------------------------------
    // Fake conversation flow (preview data)
    // ------------------------------------------------------------------
    function _submit() {
        var text = input.text.trim()
        var paths = root.attachmentPaths()
        if (text.length === 0 && paths.length === 0)
            return
        var staged = root.attachments.slice()
        input.text = ""
        // Clear before emitting so the host can put the chips back if the send
        // fails; a successful submit leaves the composer empty.
        root.clearAttachments()
        root.submitText(text, paths)
        // Keep the composer ready for the next turn, including after a voice reply.
        input.forceActiveFocus()

        if (!root.fakeMode)
            return

        var shown = text
        if (shown.length === 0)
            shown = "(" + staged.length + (staged.length === 1 ? " attachment)" : " attachments)")
        root.clearMedia()
        root.userText = shown
        root._addTurn("user", shown)
        root.replyText = ""
        root.metrics = ""
        root.status = "Thinking"
        root._pendingReply = _fakeReplyFor(shown)
        thinkTimer.restart()
    }

    function _beginListening() {
        if (root.listening)
            return
        root.listening = true
        root.status = "Listening"
        root.audioLevel = 0.25
        root.startListening()
    }

    function _endListening(commit) {
        if (!root.listening)
            return
        root.listening = false
        root.audioLevel = 0
        root.stopListening()

        if (!root.fakeMode) {
            // The backend owns the rest; show Thinking until it answers.
            root.status = commit ? "Thinking" : "Ready"
            input.forceActiveFocus()
            return
        }

        if (!commit) {
            root.status = "Ready"
            return
        }

        root.userText = "How does this sound?"
        root._addTurn("user", root.userText)
        root.replyText = ""
        root.metrics = ""
        root.status = "Thinking"
        root._pendingReply = "Clear and local. Everything stays on this machine."
        thinkTimer.restart()
    }

    function _toggleListening() {
        if (root.isListening) {
            if (root.listening) {
                _endListening(true)
            } else {
                root.stopListening()
                root.status = "Ready"
            }
        } else {
            _beginListening()
        }
    }

    function _cancel() {
        if (root.attachmentPickerOpen) {
            attachmentPicker.dismiss()
            return
        }
        if (root.modelMenuOpen) {
            root.modelMenuOpen = false
            return
        }
        if (root.transcriptOpen) {
            root.transcriptOpen = false
            return
        }
        if (root.isListening) {
            if (root.listening)
                _endListening(false)
            else
                root.stopListening()
            root.status = "Ready"
            root.cancel()
            return
        }
        if (root.stateKey === "thinking" || root.stateKey === "speaking") {
            root.status = "Ready"
            root.cancel()
            return
        }
        root.cancel()
    }

    function _newConversation() {
        if (root.isListening) {
            if (root.listening)
                _endListening(false)
            else
                root.stopListening()
        }
        root.userText = ""
        root.replyText = ""
        root.metrics = ""
        root.turns = []
        root.toolEvents = []
        root.clearAttachments()
        root.clearMedia()
        root.status = "Ready"
        root.newConversation()
        input.forceActiveFocus()
    }

    // ------------------------------------------------------------------
    // Fonts
    // ------------------------------------------------------------------
    FontLoader { id: serifFont; source: "fonts/Newsreader.ttf" }
    // Registers the real italic face for the same family; used via font.italic.
    FontLoader { id: serifItalicFont; source: "fonts/Newsreader-Italic.ttf" }
    FontLoader { id: sansFont; source: "fonts/SchibstedGrotesk.ttf" }

    // ------------------------------------------------------------------
    // Stage
    // ------------------------------------------------------------------
    Rectangle {
        anchors.fill: parent
        color: root.stageColor
    }

    // Ambient room light in the orb's state colour.
    Canvas {
        id: ambient
        anchors.fill: parent
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
            target: root
            function onStateColorChanged() { ambient.requestPaint() }
        }
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var w = width
            var h = height
            var cx = w / 2
            var cy = Math.min(h * 0.3, 260)
            var r = Math.max(w, h) * 0.85
            var c = root.stateColor
            var g = ctx.createRadialGradient(cx, cy, 0, cx, cy, r)
            g.addColorStop(0, Qt.rgba(c.r, c.g, c.b, 0.15))
            g.addColorStop(0.45, Qt.rgba(c.r, c.g, c.b, 0.07))
            g.addColorStop(1, Qt.rgba(c.r, c.g, c.b, 0.0))
            ctx.fillStyle = g
            ctx.fillRect(0, 0, w, h)
        }
    }

    // ------------------------------------------------------------------
    // Header: model, status, voice toggle, transcript
    // ------------------------------------------------------------------
    Item {
        id: header
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
            topMargin: 8
            leftMargin: root.contentPadding
            rightMargin: 10
        }
        height: 30

        // Model pill: the main model identity of the tab.
        Rectangle {
            id: modelPill
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(200, root.width * 0.5)
            height: 30
            radius: 15
            color: root.modelMenuOpen ? "#eb26303d" : root.glass
            border.width: 1
            border.color: root.modelMenuOpen ? "#40ffffff" : root.line
            Behavior on border.color { ColorAnimation { duration: 180 } }

            Row {
                id: pillRow
                anchors.left: parent.left
                anchors.leftMargin: 11
                anchors.right: pillChevron.left
                anchors.rightMargin: 5
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                Rectangle {
                    id: pillLoadedDot
                    anchors.verticalCenter: parent.verticalCenter
                    width: 5
                    height: 5
                    radius: 2.5
                    color: root.loadedColor
                    opacity: root.currentModelLoaded ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                }

                Text {
                    width: pillRow.width - 11
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.modelPillLabel
                    color: root.currentModelName.length > 0 ? root.ink : root.muted
                    font.family: root.sansFamily
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }
            }

            Icon {
                id: pillChevron
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 12
                height: 12
                kind: "chevron-down"
                color: root.ink2
                rotation: root.modelMenuOpen ? 180 : 0
                Behavior on rotation { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            }

            MouseArea {
                id: pillHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleModelMenu()
            }
        }

        // Status stays in the header, without repeating the model name.
        Row {
            anchors.left: modelPill.right
            anchors.leftMargin: 9
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5

            Item {
                width: 12
                height: 12

                Rectangle {
                    width: 6
                    height: 6
                    radius: 3
                    color: root.stateColor
                    anchors.centerIn: parent
                    Behavior on color { ColorAnimation { duration: 400 } }
                }

                Rectangle {
                    anchors.centerIn: parent
                    width: 12
                    height: 12
                    radius: 6
                    color: "transparent"
                    border.color: root.stateColor
                    border.width: 1
                    visible: root.busy
                    SequentialAnimation on opacity {
                        running: root.busy
                        loops: Animation.Infinite
                        NumberAnimation { from: 0.7; to: 0; duration: 1500; easing.type: Easing.OutCubic }
                        PauseAnimation { duration: 200 }
                    }
                    SequentialAnimation on scale {
                        running: root.busy
                        loops: Animation.Infinite
                        NumberAnimation { from: 0.45; to: 1.35; duration: 1500; easing.type: Easing.OutCubic }
                        PauseAnimation { duration: 200 }
                    }
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.status
                color: root.muted
                font.family: root.sansFamily
                font.pixelSize: 11
            }
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            // Spoken replies toggle (visual only in this milestone).
            Rectangle {
                width: 28
                height: 28
                radius: 14
                color: voiceHover.containsMouse ? "#12ffffff" : "transparent"
                Icon {
                    anchors.centerIn: parent
                    kind: root.voiceOn ? "speaker" : "speaker-off"
                    color: voiceHover.containsMouse ? root.ink : root.ink2
                    width: 17
                    height: 17
                }
                MouseArea {
                    id: voiceHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.voiceOn = !root.voiceOn
                }
            }

            // Transcript toggle with turn badge.
            Rectangle {
                width: 28
                height: 28
                radius: 14
                color: transcriptHover.containsMouse || root.transcriptOpen ? "#12ffffff" : "transparent"
                Icon {
                    anchors.centerIn: parent
                    kind: "transcript"
                    color: transcriptHover.containsMouse || root.transcriptOpen ? root.ink : root.ink2
                    width: 17
                    height: 17
                }
                Rectangle {
                    visible: root.turnCount > 0
                    anchors.right: parent.right
                    anchors.top: parent.top
                    width: Math.max(13, badgeText.implicitWidth + 6)
                    height: 13
                    radius: 6.5
                    color: root.ink
                    Text {
                        id: badgeText
                        anchors.centerIn: parent
                        text: root.turnCount
                        color: "#121922"
                        font.family: root.sansFamily
                        font.pixelSize: 9
                        font.weight: Font.DemiBold
                    }
                }
                MouseArea {
                    id: transcriptHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.transcriptOpen = !root.transcriptOpen
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Dock: glass composer and hint, pinned to the tab bottom
    // ------------------------------------------------------------------
    Item {
        id: dock
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        // The attachment strip pushes the composer up instead of covering it.
        height: root.hasAttachments ? 122 : 88

        AttachmentBar {
            id: attachmentBar
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                leftMargin: 14
                rightMargin: 14
            }
            height: 26
            visible: root.hasAttachments
            attachments: root.attachments
            ink: root.ink
            ink2: root.ink2
            muted: root.muted
            line: root.line2
            glass: root.glass
            sansFamily: root.sansFamily
            onRemoveRequested: (index) => root.removeAttachment(index)
        }

        Rectangle {
            id: composer
            anchors.top: root.hasAttachments ? attachmentBar.bottom : parent.top
            anchors.topMargin: root.hasAttachments ? 8 : 0
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 24
            height: 52
            radius: 26
            color: root.dropActive ? "#382cc4d8" : root.glass
            border.width: 1
            border.color: root.dropActive ? root.listenColor
                                           : root.isListening ? Qt.rgba(root.listenColor.r, root.listenColor.g, root.listenColor.b, 0.55) : root.line
            Behavior on border.color { ColorAnimation { duration: 300 } }

            // Glass sheen along the top edge.
            Rectangle {
                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                    margins: 1
                }
                height: 24
                radius: parent.radius - 1
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#10ffffff" }
                    GradientStop { position: 1.0; color: "#00ffffff" }
                }
            }

            // Drag feedback: the file manager shows the cursor over this hint.
            Rectangle {
                anchors.fill: parent
                visible: root.dropActive
                radius: parent.radius
                color: "#292cc4d8"
                border.width: 1
                border.color: root.listenColor

                Text {
                    anchors.centerIn: parent
                    text: "Drop to attach"
                    color: root.ink
                    font.family: root.sansFamily
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                }
            }

            // Attach images, video, or audio for the next message.
            Item {
                id: attachButton
                anchors {
                    left: parent.left
                    leftMargin: 4
                    verticalCenter: parent.verticalCenter
                }
                width: 30
                height: 40

                Shape {
                    anchors.centerIn: parent
                    width: 24
                    height: 24
                    scale: 0.78
                    antialiasing: true
                    ShapePath {
                        strokeColor: attachHover.containsMouse ? root.ink : root.muted
                        strokeWidth: 1.9
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        joinStyle: ShapePath.RoundJoin
                        PathSvg {
                            path: "M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l8.57-8.57A4 4 0 1 1 18 8.84l-8.59 8.57a2 2 0 0 1-2.83-2.83l8.49-8.48"
                        }
                    }
                }

                MouseArea {
                    id: attachHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openAttachmentPicker()
                }
            }

            Item {
                id: field
                anchors {
                    left: attachButton.right
                    right: micButton.left
                    top: parent.top
                    bottom: parent.bottom
                    leftMargin: 2
                    rightMargin: 4
                }

                TapHandler {
                    onTapped: input.forceActiveFocus()
                }

                Text {
                    anchors.fill: parent
                    anchors.topMargin: 14
                    text: "Message"
                    visible: input.text.length === 0
                    color: root.muted
                    font.family: root.sansFamily
                    font.pixelSize: 15
                }

                TextEdit {
                    id: input
                    anchors.fill: parent
                    anchors.topMargin: 13
                    anchors.bottomMargin: 11
                    color: root.ink
                    selectionColor: Qt.rgba(root.listenColor.r, root.listenColor.g, root.listenColor.b, 0.45)
                    selectedTextColor: root.ink
                    font.family: root.sansFamily
                    font.pixelSize: 15
                    wrapMode: TextEdit.Wrap
                    selectByMouse: true
                    activeFocusOnPress: true
                    clip: true
                    // Keep the empty composer clean (placeholder, no bare caret).
                    cursorVisible: text.length > 0

                    Keys.onPressed: (event) => {
                        if (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) {
                            event.accepted = true
                            root.scrollConversation(event.key === Qt.Key_PageUp
                                                    ? -scroller.height * 0.85
                                                    : scroller.height * 0.85)
                            return
                        }
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            if (event.modifiers & Qt.ShiftModifier)
                                return
                            event.accepted = true
                            root._submit()
                            return
                        }
                        if (event.key === Qt.Key_Escape) {
                            event.accepted = true
                            root._cancel()
                            return
                        }
                        if (event.key === Qt.Key_Space && !event.isAutoRepeat) {
                            if (input.text.length === 0) {
                                event.accepted = true
                                root._beginListening()
                            }
                        }
                    }
                    Keys.onReleased: (event) => {
                        if (event.key === Qt.Key_Space && !event.isAutoRepeat && root.listening) {
                            event.accepted = true
                            root._endListening(true)
                        }
                    }
                }
            }

            Rectangle {
                id: micButton
                anchors {
                    right: parent.right
                    rightMargin: 6
                    verticalCenter: parent.verticalCenter
                }
                width: 40
                height: 40
                radius: 20
                color: root.ink
                scale: micArea.pressed ? 0.94 : 1.0
                Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

                Icon {
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    color: "#121922"
                    kind: root.isListening ? "stop" : (input.text.trim().length > 0 ? "send" : "mic")
                }

                MouseArea {
                    id: micArea
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    property real pressedAt: 0
                    property bool startedThisPress: false
                    onPressed: {
                        pressedAt = Date.now()
                        startedThisPress = false
                        if (!root.listening) {
                            startedThisPress = true
                            root._beginListening()
                        }
                    }
                    onReleased: {
                        if (root.isListening && Date.now() - pressedAt > 240)
                            root._toggleListening()
                    }
                    onClicked: {
                        if (Date.now() - pressedAt > 240)
                            return
                        if (startedThisPress)
                            return
                        if (input.text.trim().length > 0)
                            root._submit()
                        else if (root.isListening)
                            root._toggleListening()
                        else
                            root._beginListening()
                    }
                }
            }
        }

        Text {
            anchors {
                top: composer.bottom
                topMargin: 8
                horizontalCenter: parent.horizontalCenter
            }
            text: root.isListening
                  ? "Listening... release to send, or press Esc to cancel."
                  : (root.busy
                     ? "Escape stops the reply."
                     : "Hold Space to talk, or press Enter to send.")
            color: root.muted
            font.family: root.sansFamily
            font.pixelSize: 11
            horizontalAlignment: Text.AlignHCenter
            Behavior on color { ColorAnimation { duration: 300 } }
        }
    }

    // ------------------------------------------------------------------
    // Body: orb and conversation, centred as one group
    // ------------------------------------------------------------------
    Item {
        id: body
        anchors {
            top: header.bottom
            left: parent.left
            right: parent.right
            bottom: dock.top
        }
        clip: true

        Column {
            id: stageColumn
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: root.stageTop
            width: parent.width
            spacing: 10

            Item {
                width: parent.width
                height: 208

                Orb {
                    id: orb
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 200
                    height: 200
                    state: root.stateKey
                    level: root.audioLevel
                    dark: root.dark
                    fill: 1
                }

                MouseArea {
                    anchors.fill: orb
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root._toggleListening()
                    onPositionChanged: (mouse) => {
                        orb.pointerX = Math.max(-1, Math.min(1, (mouse.x - width / 2) / (width / 2)))
                        orb.pointerY = -Math.max(-1, Math.min(1, (mouse.y - height / 2) / (height / 2)))
                    }
                    onExited: {
                        orb.pointerX = 0
                        orb.pointerY = 0
                    }
                }
            }

            Item {
                id: convoViewport
                objectName: "convoViewport"
                width: parent.width
                height: Math.min(convo.implicitHeight, root.convoMaxHeight)

                Flickable {
                    id: scroller
                    objectName: "convoScroller"
                    anchors.fill: parent
                    contentWidth: width
                    contentHeight: convo.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: true
                    flickableDirection: Flickable.VerticalFlick

                    // Follow the stream while the reader stays at the bottom.
                    onContentHeightChanged: {
                        if (root._stickToEnd)
                            Qt.callLater(root.scrollToEnd)
                    }
                    onContentYChanged: {
                        var maxY = Math.max(0, contentHeight - height)
                        if (moving || dragging)
                            root._stickToEnd = contentY >= maxY - 8
                    }
                    onMovementEnded: {
                        var maxY = Math.max(0, contentHeight - height)
                        root._stickToEnd = contentY >= maxY - 8
                    }

                    Column {
                        id: convo
                        width: scroller.width - 44
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 9
                        bottomPadding: 4

                        // Empty state, like the Space intro.
                        Text {
                            visible: !root.hasConversation
                            width: parent.width
                            text: "Talk to me, or type."
                            color: root.ink
                            font.family: root.serifFamily
                            font.pixelSize: 27
                            font.weight: Font.Light
                            lineHeight: 1.1
                            lineHeightMode: Text.ProportionalHeight
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                        }
                        Text {
                            visible: !root.hasConversation
                            width: parent.width
                            text: "Hold Space to talk, or type below."
                            color: root.muted
                            font.family: root.sansFamily
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                        }

                        Text {
                            id: userLabel
                            visible: root.userText.length > 0
                            width: parent.width
                            text: root.userText
                            color: root.muted
                            font.family: root.sansFamily
                            font.pixelSize: 13
                            lineHeight: 1.35
                            lineHeightMode: Text.ProportionalHeight
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                            maximumLineCount: 3
                            elide: Text.ElideRight
                        }

                        // Tool activity chips, wrapped for the narrow column.
                        Flow {
                            width: parent.width
                            visible: root.toolEvents.length > 0
                            spacing: 6
                            layoutDirection: Qt.LeftToRight
                            Repeater {
                                model: root.toolEvents
                                delegate: Rectangle {
                                    height: 24
                                    width: chipRow.implicitWidth + 18
                                    radius: 12
                                    color: "transparent"
                                    border.width: 1
                                    border.color: root.line2
                                    Row {
                                        id: chipRow
                                        anchors.centerIn: parent
                                        spacing: 6
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 5
                                            height: 5
                                            radius: 2.5
                                            color: modelData.status === "failed" ? "#ff6369"
                                                   : (modelData.status === "running" ? root.thinkColor : root.listenColor)
                                        }
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.summary || modelData.name
                                            color: root.ink2
                                            font.family: root.sansFamily
                                            font.pixelSize: 11
                                        }
                                    }
                                }
                            }
                        }

                        // Reply in Newsreader, centred like the Space caption.
                        // The rich renderer (markdown + LaTeX) is injected by
                        // IntelligencePage; preview keeps this plain Text.
                        Item {
                            id: replyArea
                            width: parent.width
                            height: root.richReplyComponent !== null
                                    ? (richReplyLoader.item ? richReplyLoader.item.implicitHeight : 0)
                                    : (plainReply.visible ? plainReply.implicitHeight : 0)
                            visible: root.replyText.length > 0
                            opacity: 0
                            transform: Translate { id: replyShift; y: 5 }

                            Component.onCompleted: if (root.replyText.length > 0) replyReveal.start()

                            Text {
                                id: plainReply
                                width: parent.width
                                visible: root.richReplyComponent === null && root.replyText.length > 0
                                text: root.replyText
                                color: root.ink
                                font.family: root.serifFamily
                                font.pixelSize: 27
                                font.weight: Font.Normal
                                font.letterSpacing: -0.25
                                lineHeight: 1.22
                                lineHeightMode: Text.ProportionalHeight
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.Wrap
                            }

                            Loader {
                                id: richReplyLoader
                                width: parent.width
                                sourceComponent: root.richReplyComponent
                                visible: root.richReplyComponent !== null && root.replyText.length > 0

                                onLoaded: {
                                    if (!item)
                                        return
                                    item.text = Qt.binding(function () { return root.replyText })
                                    item.done = Qt.binding(function () { return !root.busy })
                                    item.textColor = Qt.binding(function () { return root.ink })
                                    item.linkColor = Qt.binding(function () { return root.listenColor })
                                    item.fontFamily = Qt.binding(function () { return root.serifFamily })
                                    item.pixelSize = 27
                                    item.lineHeight = 1.22
                                    item.dark = root.dark
                                    replyReveal.restart()
                                }
                                onItemChanged: if (item) replyReveal.restart()
                            }

                            Connections {
                                target: root
                                function onReplyTextChanged() {
                                    if (root.replyText.length === 0) {
                                        replyReveal.stop()
                                        replyArea.opacity = 0
                                        replyShift.y = 5
                                    } else if (!replyReveal.running && replyArea.opacity < 0.999) {
                                        replyReveal.restart()
                                    }
                                }
                            }

                            SequentialAnimation {
                                id: replyReveal
                                NumberAnimation {
                                    target: replyArea
                                    property: "opacity"
                                    from: 0
                                    to: 1
                                    duration: 420
                                    easing.type: Easing.OutCubic
                                }
                                NumberAnimation {
                                    target: replyShift
                                    property: "y"
                                    from: 5
                                    to: 0
                                    duration: 300
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }

                        Text {
                            visible: root.metrics.length > 0
                            width: parent.width
                            text: root._metricsHtml()
                            textFormat: Text.StyledText
                            color: root.muted
                            font.family: root.sansFamily
                            font.pixelSize: 11
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                        }

                        // DigUp media previews sit below the assistant reply.
                        Column {
                            id: mediaList
                            width: parent.width
                            visible: root.hasMedia
                            spacing: 8

                            Text {
                                width: parent.width
                                visible: root.mediaQuery.length > 0
                                text: root.mediaQuery.length > 0
                                      ? "Media for \u201c" + root.mediaQuery + "\u201d"
                                      : ""
                                color: root.muted
                                font.family: root.sansFamily
                                font.pixelSize: 10
                                font.letterSpacing: 0.6
                                font.capitalization: Font.AllUppercase
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.Wrap
                            }

                            Repeater {
                                model: root.mediaResults

                                delegate: Item {
                                    id: mediaSlot
                                    required property var modelData
                                    required property int index

                                    width: mediaList.width
                                    height: mediaLoader.item ? mediaLoader.item.implicitHeight
                                                            : mediaFallback.height

                                    Loader {
                                        id: mediaLoader
                                        width: parent.width
                                        sourceComponent: root.mediaPreviewComponent

                                        onLoaded: {
                                            if (!item)
                                                return
                                            item.result = Qt.binding(function () { return mediaSlot.modelData })
                                            item.ink = root.ink
                                            item.ink2 = root.ink2
                                            item.muted = root.muted
                                            item.line = root.line2
                                            item.glass = root.glass
                                            item.accent = root.listenColor
                                            item.sansFamily = root.sansFamily
                                            item.serifFamily = root.serifFamily
                                            item.dark = root.dark
                                        }
                                    }

                                    // Plain fallback (preview, or a component that
                                    // failed to load): path and kind only.
                                    Rectangle {
                                        id: mediaFallback
                                        width: parent.width
                                        height: 46
                                        visible: mediaLoader.status !== Loader.Ready
                                        radius: 10
                                        color: root.glass
                                        border.width: 1
                                        border.color: root.line

                                        Text {
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.margins: 10
                                            text: (mediaSlot.modelData && mediaSlot.modelData.path
                                                   ? String(mediaSlot.modelData.path).split("/").pop()
                                                   : "file")
                                                  + "  \u00b7  "
                                                  + (mediaSlot.modelData && mediaSlot.modelData.kind
                                                     ? mediaSlot.modelData.kind : "file")
                                            color: root.ink2
                                            font.family: root.sansFamily
                                            font.pixelSize: 11
                                            elide: Text.ElideMiddle
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Slim scrollbar for the conversation; fades in on overflow.
                Rectangle {
                    id: scrollThumb
                    objectName: "scrollThumb"
                    readonly property real maxY: Math.max(0, scroller.contentHeight - scroller.height)
                    visible: maxY > 1
                    width: 3
                    radius: 1.5
                    color: root.ink
                    opacity: scroller.moving || scroller.flicking ? 0.55 : 0.18
                    x: convoViewport.width - 9
                    height: Math.max(22, scroller.height * scroller.height / Math.max(1, scroller.contentHeight))
                    y: maxY > 0 ? (scroller.height - height) * (scroller.contentY / maxY) : 0
                    Behavior on opacity { NumberAnimation { duration: 220 } }
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Transcript
    // ------------------------------------------------------------------
    Item {
        id: transcript
        anchors {
            top: header.bottom
            left: parent.left
            right: parent.right
            bottom: dock.top
            topMargin: 6
        }
        visible: opacity > 0.01
        opacity: root.transcriptOpen ? 1 : 0
        x: root.transcriptOpen ? 0 : 18
        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on x { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

        Rectangle {
            anchors.fill: parent
            color: root.panel
        }

        Item {
            id: transcriptHead
            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
                leftMargin: 16
                rightMargin: 10
            }
            height: 42

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Transcript"
                color: root.ink
                font.family: root.serifFamily
                font.italic: true
                font.pixelSize: 21
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Rectangle {
                    width: newLabel.implicitWidth + 18
                    height: 24
                    radius: 12
                    color: newHover.containsMouse ? "#14ffffff" : "transparent"
                    border.width: 1
                    border.color: root.line2
                    Text {
                        id: newLabel
                        anchors.centerIn: parent
                        text: "New conversation"
                        color: root.ink2
                        font.family: root.sansFamily
                        font.pixelSize: 11
                    }
                    MouseArea {
                        id: newHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root._newConversation()
                    }
                }

                Rectangle {
                    width: 26
                    height: 26
                    radius: 13
                    color: closeHover.containsMouse ? "#14ffffff" : "transparent"
                    Icon {
                        anchors.centerIn: parent
                        kind: "close"
                        color: closeHover.containsMouse ? root.ink : root.ink2
                        width: 15
                        height: 15
                    }
                    MouseArea {
                        id: closeHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.transcriptOpen = false
                    }
                }
            }
        }

        ListView {
            id: log
            anchors {
                top: transcriptHead.bottom
                left: parent.left
                right: parent.right
                bottom: parent.bottom
                leftMargin: 16
                rightMargin: 16
                bottomMargin: 12
            }
            model: root.turns
            spacing: 0
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            onCountChanged: positionViewAtEnd()

            delegate: Item {
                width: log.width
                height: turnColumn.height + 17

                Column {
                    id: turnColumn
                    width: parent.width - 6
                    topPadding: 10
                    spacing: 5

                    Row {
                        spacing: 8
                        Text {
                            text: modelData.role === "user" ? "You" : root.modelName
                            color: root.ink2
                            font.family: root.sansFamily
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                        }
                        Text {
                            text: modelData.at || ""
                            color: root.muted
                            font.family: root.sansFamily
                            font.pixelSize: 10
                        }
                    }

                    Text {
                        width: parent.width
                        text: modelData.text || ""
                        color: modelData.role === "user" ? root.ink2 : root.ink
                        font.family: modelData.role === "user" ? root.sansFamily : root.serifFamily
                        font.pixelSize: modelData.role === "user" ? 13 : 16
                        lineHeight: 1.28
                        lineHeightMode: Text.ProportionalHeight
                        wrapMode: Text.Wrap
                    }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: root.line
                }
            }

            Text {
                visible: log.count === 0
                anchors.centerIn: parent
                width: parent.width - 40
                text: "Nothing here yet."
                color: root.muted
                font.family: root.serifFamily
                font.italic: true
                font.pixelSize: 18
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
            }
        }
    }

    // ------------------------------------------------------------------
    // Fake reply timers
    // ------------------------------------------------------------------
    Timer {
        id: thinkTimer
        interval: 720
        onTriggered: {
            if (!root.fakeMode)
                return
            root.replyText = root._pendingReply
            root.metrics = "First word in " + (0.52 + Math.random() * 0.2).toFixed(2)
                         + " s, voice in " + (0.82 + Math.random() * 0.2).toFixed(2) + " s"
            root._addTurn("assistant", root.replyText)
            root.status = "Speaking"
            orb.sendPulse()
            settleTimer.restart()
        }
    }

    Timer {
        id: settleTimer
        interval: 2600
        onTriggered: {
            if (root.status === "Speaking")
                root.status = "Ready"
        }
    }

    // Simulated audio level so the shader moves while listening or speaking.
    Timer {
        id: levelTimer
        interval: 60
        repeat: true
        running: root.busy && root.fakeMode
        onTriggered: {
            if (root.stateKey === "listening") {
                var n = Date.now() / 90
                root.audioLevel = Math.max(0.12, Math.min(1, 0.42 + 0.28 * Math.sin(n) + 0.18 * Math.random()))
            } else if (root.stateKey === "speaking") {
                root.audioLevel = Math.max(0.08, Math.min(0.7, 0.28 + 0.18 * Math.sin(Date.now() / 120)))
            } else {
                root.audioLevel = 0.08
            }
        }
    }

    onBusyChanged: {
        if (!root.busy)
            root.audioLevel = 0
    }

    // ------------------------------------------------------------------
    // Keyboard
    // ------------------------------------------------------------------
    onActiveFocusChanged: {
        if (activeFocus)
            input.forceActiveFocus()
    }

    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) {
            event.accepted = true
            root._cancel()
            return
        }
        if (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) {
            event.accepted = true
            root.scrollConversation(event.key === Qt.Key_PageUp
                                    ? -scroller.height * 0.85
                                    : scroller.height * 0.85)
            return
        }
        if (event.key === Qt.Key_Space && !event.isAutoRepeat) {
            event.accepted = true
            root._beginListening()
        }
    }

    Keys.onReleased: (event) => {
        if (event.key === Qt.Key_Space && !event.isAutoRepeat && root.listening) {
            event.accepted = true
            root._endListening(true)
        }
    }

    // ------------------------------------------------------------------
    // Model menu: glass dropdown under the pill
    // ------------------------------------------------------------------
    Item {
        id: modelMenuLayer
        anchors.fill: parent
        z: 100
        visible: root.modelMenuOpen

        Rectangle {
            anchors.fill: parent
            color: "#18000000"
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.modelMenuOpen = false
        }

        Rectangle {
            id: modelMenu
            x: root.modelMenuX
            y: root.modelMenuY
            width: root.modelMenuWidth
            height: menuColumn.implicitHeight + 16
            radius: 14
            color: "#f21e2732"
            border.width: 1
            border.color: root.line2

            // Swallow clicks on the panel padding so only the scrim closes it.
            MouseArea {
                anchors.fill: parent
            }

            Column {
                id: menuColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 8
                spacing: 2

                Item {
                    width: parent.width
                    height: 24

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Models"
                        color: root.muted
                        font.family: root.sansFamily
                        font.pixelSize: 10
                        font.letterSpacing: 1.0
                        font.capitalization: Font.AllUppercase
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.modelCount === 1 ? "1 model" : root.modelCount + " models"
                        color: root.muted
                        font.family: root.sansFamily
                        font.pixelSize: 10
                    }
                }

                Repeater {
                    model: root.models

                    delegate: Rectangle {
                        width: menuColumn.width
                        height: 46
                        radius: 9
                        color: rowHover.containsMouse ? "#16ffffff"
                               : (modelData.id === root.currentModel ? "#0cffffff" : "transparent")

                        Rectangle {
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            visible: modelData.loaded === true
                            width: 6
                            height: 6
                            radius: 3
                            color: root.loadedColor
                        }

                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: 24
                            anchors.right: modelCheck.left
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1

                            Text {
                                width: parent.width
                                text: modelData.name || modelData.id
                                color: root.ink
                                font.family: root.sansFamily
                                font.pixelSize: 13
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                            }

                            Text {
                                width: parent.width
                                text: modelData.size || ""
                                color: root.muted
                                font.family: root.sansFamily
                                font.pixelSize: 10
                                elide: Text.ElideRight
                            }
                        }

                        Icon {
                            id: modelCheck
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            width: 13
                            height: 13
                            kind: "check"
                            color: root.ink
                            visible: modelData.id === root.currentModel
                        }

                        MouseArea {
                            id: rowHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.chooseModel(modelData.id)
                        }
                    }
                }

                // Explicit unload for the model currently in memory, so the
                // card can be freed without switching models or restarting.
                Rectangle {
                    id: unloadRow
                    width: parent.width
                    height: 34
                    radius: 9
                    visible: root.currentModelLoaded && root.currentModel.length > 0
                    color: unloadHover.containsMouse ? "#1fff6b6b" : "transparent"

                    Icon {
                        id: unloadIcon
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: 11
                        height: 11
                        kind: "close"
                        color: unloadHover.containsMouse ? "#ff9a9a" : root.ink2
                    }

                    Text {
                        anchors.left: unloadIcon.right
                        anchors.leftMargin: 8
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Unload " + root.currentModelName
                        color: unloadHover.containsMouse ? "#ffb3b3" : root.ink2
                        font.family: root.sansFamily
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }

                    MouseArea {
                        id: unloadHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.unloadCurrentModel()
                    }
                }

                Text {
                    width: parent.width
                    height: 40
                    visible: root.modelCount === 0
                    text: "No models found"
                    color: root.muted
                    font.family: root.sansFamily
                    font.pixelSize: 11
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    // When DigUp media lands, keep the answer in view instead of following the
    // new cards to the bottom. Still above the previews, just readable.
    Connections {
        target: root
        function onMediaResultsChanged() {
            if (root.mediaResults.length === 0 || !replyArea || replyArea.height <= 0)
                return
            root._stickToEnd = false
            Qt.callLater(function () {
                var maxY = Math.max(0, scroller.contentHeight - scroller.height)
                var y = replyArea.mapToItem(convo, 0, 0).y
                scroller.contentY = Math.max(0, Math.min(maxY, y - 6))
            })
        }
    }

    // ------------------------------------------------------------------
    // Attachment picker and drag and drop
    // ------------------------------------------------------------------
    AttachmentPicker {
        id: attachmentPicker
        anchors.fill: parent
        ink: root.ink
        ink2: root.ink2
        muted: root.muted
        line: root.line2
        accent: root.idleColor
        sansFamily: root.sansFamily
        onAttachRequested: (paths) => {
            for (var i = 0; i < paths.length; ++i)
                root.addAttachment(paths[i])
        }
        onClosed: Qt.callLater(() => root.focusComposer())
    }

    // Files dropped from Dolphin or another file manager. The area spans the
    // page so a drop works above the composer and over the picker.
    DropArea {
        anchors.fill: parent
        z: 900
        onEntered: (drag) => {
            drag.accepted = drag.hasUrls
            if (drag.hasUrls)
                root.dropActive = true
        }
        onExited: root.dropActive = false
        onDropped: (drop) => {
            root.dropActive = false
            if (!drop.hasUrls) {
                drop.accepted = false
                return
            }
            var added = root.addDroppedUrls(drop.urls)
            drop.accepted = added > 0
            if (added > 0)
                Qt.callLater(() => root.focusComposer())
        }
    }

    // Focus is not requested on load: the sidebar creates every page, and the
    // page should not steal keyboard focus from the active tab. The sidebar
    // calls focusActiveItem() on open, which lands here via activeFocus.
    Component.onCompleted: {
        if (root.activeFocus)
            input.forceActiveFocus()
    }
}
