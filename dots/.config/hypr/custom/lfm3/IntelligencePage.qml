// Quickshell wrapper around the pure-QtQuick Intelligence tab.
//
// This file owns the bridge process. IntelligenceTab.qml stays free of
// Quickshell imports so it can still be previewed with qml6.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Item {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string bridgePath: Quickshell.env("LFM3_BRIDGE") || (root.home + "/.config/lfm3-assistant/lfm3_bridge.py")

    property bool bridgeReady: false
    property bool bridgeFailed: false
    property bool isCurrentPage: true

    // Small integration surface for the sidebar/tests. The page itself is not
    // exposed as a window; it is the Intelligence tab content.
    property alias tabItem: tab
    property alias models: tab.models
    property alias currentModel: tab.currentModel
    property alias status: tab.status
    property alias replyText: tab.replyText
    property alias userText: tab.userText
    property alias voiceOn: tab.voiceOn
    property alias inputActive: tab.inputActive
    property alias attachments: tab.attachments
    property alias mediaResults: tab.mediaResults
    property alias mediaQuery: tab.mediaQuery

    onVoiceOnChanged: send({ "cmd": "set_voice", "enabled": tab.voiceOn })
    onActiveFocusChanged: {
        if (activeFocus)
            tab.focusComposer()
    }

    IntelligenceTab {
        id: tab
        anchors.fill: parent
        fakeMode: false
        userText: ""
        replyText: ""
        metrics: ""
        turns: []
        toolEvents: []
        status: "Ready"

        // Rich reply (markdown + LaTeX via the ii LatexRenderer) and DigUp media
        // cards. IntelligenceTab.qml stays Qt Quick only and falls back to plain
        // text when these components are absent.
        richReplyComponent: Component { RichReply {} }
        mediaPreviewComponent: Component { MediaPreview {} }

        onSubmitText: (text, attachments) => {
            if (!root.send({ "cmd": "text", "text": text, "attachments": attachments || [] })) {
                // The tab cleared the composer optimistically; put it back so the
                // user can retry once the bridge is running.
                tab.setDraft(text)
                for (var i = 0; i < (attachments || []).length; ++i)
                    tab.addAttachment(attachments[i])
            }
        }
        onStartListening: {
            tab.status = "Listening"
            root.send({ "cmd": "start_listen" })
        }
        onStopListening: commit => root.send({ "cmd": "stop_listen", "commit": commit })
        onCancel: {
            tab.status = "Ready"
            root.send({ "cmd": "cancel" })
        }
        onNewConversation: {
            tab.userText = ""
            tab.replyText = ""
            tab.metrics = ""
            tab.turns = []
            tab.toolEvents = []
            tab.clearMedia()
            tab.queuedCount = 0
            tab.status = "Ready"
            root.send({ "cmd": "new" })
        }
        onSelectModel: id => {
            tab.status = "Loading"
            root.send({ "cmd": "model_select", "id": id })
        }
        onUnloadModel: id => {
            if (!id)
                return
            tab.status = "Loading"
            root.send({ "cmd": "model_unload", "id": id })
        }
    }

    // The audio stream moves keyboard focus away when a turn ends. The layer
    // surface stays mapped, but the compositor stops routing keys to it and Qt
    // clears the scene focus chain (activeFocusItem falls back to the root
    // item). A focus request inside the scene cannot fix that: the window must
    // ask the compositor for keyboard focus again, then the composer can take
    // it. WlrLayershell.keyboardFocus stays OnDemand so click-outside still
    // collapses the sidebar.
    function focusKick() {
        var win = root.Window.window
        if (!win)
            return
        try {
            // requestActivate alone is not reliable for a layer-shell surface
            // after the audio stream releases the keyboard. Hold Exclusive for
            // a short moment, then return to OnDemand for click-outside close.
            win.WlrLayershell.keyboardFocus = WlrKeyboardFocus.Exclusive
            focusKickEnd.restart()
        } catch (e) {
            // ignore; the normal focus path still runs
        }
        win.requestActivate()
    }

    function restoreFocus() {
        if (!root.isCurrentPage || !root.visible)
            return
        if (tab.modelMenuOpen || tab.transcriptOpen || tab.attachmentPickerOpen || tab.listening)
            return

        root.focusKick()
        Qt.callLater(() => tab.focusComposer())
        focusRetry.restart()
    }

    Timer {
        id: focusKickEnd
        interval: 160
        repeat: false
        onTriggered: {
            var win = root.Window.window
            if (!win)
                return
            try {
                win.WlrLayershell.keyboardFocus = WlrKeyboardFocus.OnDemand
            } catch (e) {
                // ignore
            }
        }
    }

    // Restore just after the stream is done, then once more shortly after:
    // speech_end/text_done/idle land before the audio device is fully released.
    Timer {
        id: focusRestore
        interval: 140
        repeat: false
        onTriggered: root.restoreFocus()
    }

    Timer {
        id: focusRetry
        interval: 90
        repeat: false
        onTriggered: {
            if (!root.isCurrentPage || !root.visible)
                return
            if (tab.modelMenuOpen || tab.transcriptOpen || tab.attachmentPickerOpen || tab.listening)
                return
            root.focusKick()
            tab.focusComposer()
            var win = root.Window.window
            if (win && !tab.inputActive)
                console.warn("[lfm3] composer focus was not restored after the turn")
        }
    }

    // A late activation (the compositor handing the surface back) also needs a
    // focus request, since the scene focus chain was already cleared.
    Connections {
        target: root.Window.window
        function onActiveChanged() {
            if (root.Window.window && root.Window.window.active)
                root.restoreFocus()
        }
    }

    // The turn end may arrive while the state is still busy; retry once it clears.
    Connections {
        target: tab
        function onBusyChanged() {
            if (!tab.busy)
                root.restoreFocus()
        }
    }

    Timer {
        interval: 700
        repeat: true
        running: true
        onTriggered: {
            if (!root.isCurrentPage || !root.visible)
                return
            if (tab.modelMenuOpen || tab.transcriptOpen || tab.attachmentPickerOpen || tab.listening)
                return
            if (!tab.inputActive) {
                root.focusKick()
                tab.focusComposer()
            }
        }
    }

    Process {
        id: bridge
        command: ["python3", root.bridgePath]
        running: true
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => root.handleLine(line)
        }
        stderr: SplitParser {
            onRead: line => console.log("[lfm3-bridge]", line)
        }
        onStarted: {
            root.bridgeReady = false
            root.bridgeFailed = false
        }
        onExited: (exitCode, exitStatus) => {
            root.bridgeReady = false
            root.bridgeFailed = true
            tab.status = "Not loaded"
            if (tab.replyText.length === 0)
                tab.replyText = "The local assistant bridge stopped. Open Intelligence again or check the bridge log."
            console.warn("[lfm3] bridge exited", exitCode, exitStatus)
        }
    }

    function send(event) {
        if (!bridge.running) {
            tab.status = "Not loaded"
            tab.replyText = "The local assistant bridge is not running."
            return false
        }
        bridge.write(JSON.stringify(event) + "\n")
        return true
    }

    function handleLine(line) {
        if (!line || line.length === 0)
            return
        var event
        try {
            event = JSON.parse(line)
        } catch (err) {
            console.warn("[lfm3] bad bridge line", line)
            return
        }

        switch (event.type) {
        case "ready":
            root.bridgeReady = true
            root.bridgeFailed = false
            tab.fakeMode = false
            tab.status = "Ready"
            tab.currentModel = ""
            tab.userText = ""
            tab.replyText = ""
            tab.metrics = ""
            tab.turns = []
            tab.toolEvents = []
            tab.clearMedia()
            tab.clearAttachments()
            tab.queuedCount = 0
            root.send({ "cmd": "models_list" })
            root.send({ "cmd": "set_voice", "enabled": tab.voiceOn })
            break

        case "models":
            tab.models = event.models || []
            // Selection is owned by the bridge. An empty currentModel means an
            // explicit unload; do not silently fall back to the first id here.
            break

        case "model":
            tab.currentModel = event.id || ""
            tab.status = "Ready"
            break

        case "queued":
        case "queue":
            tab.queuedCount = Math.max(0, Number(event.pending) || 0)
            focusRestore.restart()
            break

        case "state":
            if (event.state === "idle") {
                tab.listening = false
                tab.status = "Ready"
                focusRestore.restart()
            } else if (event.state === "listening")
                tab.status = "Listening"
            else if (event.state === "thinking")
                tab.status = "Thinking"
            else if (event.state === "speaking")
                tab.status = "Speaking"
            break

        case "user":
            tab.userText = event.text || ""
            tab.replyText = ""
            tab.metrics = ""
            tab.toolEvents = []
            tab.clearMedia()
            if (tab.userText.length > 0)
                tab._addTurn("user", tab.userText)
            break

        case "text_delta":
            if (event.text) {
                tab.replyText += event.text
                if (tab.status === "Thinking")
                    tab.status = "Speaking"
            }
            break

        case "text_done":
            tab.replyText = event.text || tab.replyText
            if (tab.replyText.length > 0)
                tab._addTurn("assistant", tab.replyText)
            if (tab.status === "Thinking" || tab.status === "Speaking")
                tab.status = "Ready"
            focusRestore.restart()
            break;

        case "tool_start":
            tab.toolEvents = tab.toolEvents.concat([{
                "name": event.name || "tool",
                "status": "running",
                "summary": ""
            }])
            break

        case "tool_end":
            var tools = tab.toolEvents.slice()
            for (var i = tools.length - 1; i >= 0; --i) {
                if (tools[i].name === event.name && tools[i].status === "running") {
                    tools[i] = {
                        "name": tools[i].name,
                        "status": event.ok === false ? "failed" : "done",
                        "summary": event.summary || (event.ok === false ? "failed" : "done")
                    }
                    break
                }
            }
            tab.toolEvents = tools
            break

        case "level":
            tab.audioLevel = Math.max(0, Math.min(1, Number(event.value) || 0))
            break

        // DigUp results for previews; the reply stays above them.
        case "media":
            tab.mediaQuery = event.query || ""
            tab.mediaResults = Array.isArray(event.results) ? event.results : []
            break

        case "speech_start":
            tab.status = "Speaking"
            break

        case "speech_end":
            if (tab.status === "Speaking")
                tab.status = "Ready"
            focusRestore.restart()
            break

        case "error":
            tab.listening = false
            tab.status = "Failed"
            tab.metrics = event.message || "Local assistant error"
            if (tab.replyText.length === 0)
                tab.replyText = event.message || "The local assistant could not answer."
            focusRestore.restart()
            break

        default:
            break
        }
    }

    Component.onDestruction: {
        if (bridge.running) {
            try {
                bridge.write(JSON.stringify({ "cmd": "shutdown" }) + "\n")
            } catch (err) {
                // process is already gone
            }
        }
    }
}
