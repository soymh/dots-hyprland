// LFM3 Translator tab: replacement content for the ii sidebar's existing
// Translator page. Native Qt Quick plus Quickshell.Io. Translation runs on the
// local llama-server model, or through Translate Shell (`trans`), selected with
// the backend pill. The model pill shares the Intelligence model choice through
// the bridge HTTP API on 127.0.0.1:8013.
//
// The visual language matches IntelligenceTab.qml: dark translucent stage,
// glass pills and composer, Newsreader for the translated text and Schibsted
// Grotesk for the UI. No orb, no shader, no globe.
//
// Designed for a narrow sidebar page: about 380-440 px wide, 800-1000 px tall.
// The sidebar owns the tab bar; this file only draws the page content.

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.modules.common as Qs

pragma ComponentBehavior: Bound

Item {
    id: root

    // ------------------------------------------------------------------
    // Integration surface
    // ------------------------------------------------------------------
    property alias inputText: input.text
    property string translatedText: ""
    property string status: "Ready"           // Ready | Translating | Failed
    property string errorText: ""
    property var translateXhr: null
    property bool fakeMode: false             // preview only: no trans calls
    property bool isCurrentPage: true
    property bool languageMenuOpen: false
    property bool languageMenuTarget: true
    property string languageFilter: ""
    property var languages: ["auto"]
    readonly property real contentPadding: 16

    // Language preferences live in the same config keys as the upstream
    // Translator, so both widgets share one choice.
    property string sourceLanguage: Qs.Config.options.language.translator.sourceLanguage || "auto"
    property string targetLanguage: Qs.Config.options.language.translator.targetLanguage || "auto"

    // Bridge HTTP API. The Intelligence model selection lives here too: POST
    // /model is the source of truth for both tabs.
    property string bridgeBaseUrl: "http://127.0.0.1:8013"
    property bool bridgeAvailable: false
    property bool bridgeChecked: false
    property var models: []
    property string currentModel: ""
    property string modelError: ""
    property bool modelMenuOpen: false
    property real modelMenuX: 12
    property real modelMenuY: 44
    readonly property real modelMenuWidth: Math.min(320, root.width - 24)

    // Translation backend: "llama" for the selected local model, otherwise a
    // Translate Shell engine ("auto", "google", "bing", "yandex").
    property string backend: "auto"
    property bool backendChosen: false
    property bool backendMenuOpen: false
    property real backendMenuX: 12
    property real backendMenuY: 44
    readonly property real backendMenuWidth: Math.min(300, root.width - 24)
    readonly property bool backendIsLocal: root.backend === "llama"
    readonly property string backendLabel: {
        switch (root.backend) {
        case "llama": return "Local LFM3"
        case "google": return "Translate Shell \u00b7 Google"
        case "bing": return "Translate Shell \u00b7 Bing"
        case "yandex": return "Translate Shell \u00b7 Yandex"
        default: return "Translate Shell \u00b7 auto"
        }
    }

    readonly property var backendOptions: [
        { "id": "llama", "title": "Local LFM3",
          "detail": root.currentModelName.length > 0 ? root.currentModelName : "llama-server",
          "recommended": root.bridgeAvailable },
        { "id": "auto", "title": "Translate Shell \u00b7 auto", "detail": "Engine chosen by Trans", "recommended": false },
        { "id": "google", "title": "Translate Shell \u00b7 Google", "detail": "", "recommended": false },
        { "id": "bing", "title": "Translate Shell \u00b7 Bing", "detail": "", "recommended": false },
        { "id": "yandex", "title": "Translate Shell \u00b7 Yandex", "detail": "", "recommended": false }
    ]

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
    readonly property string modelPillText: {
        if (!root.bridgeChecked)
            return "Checking local model\u2026"
        if (!root.bridgeAvailable)
            return "Local model unavailable"
        return root.currentModelName.length > 0 ? root.currentModelName : "Choose a model"
    }

    readonly property int debounceInterval: {
        var delay = Qs.Config.options.sidebar.translator.delay
        return delay > 0 ? delay : 320
    }

    readonly property bool busy: root.status === "Translating"
    readonly property bool failed: root.status === "Failed"
    readonly property bool hasInput: root.inputText.trim().length > 0
    readonly property bool hasOutput: root.translatedText.trim().length > 0

    readonly property var filteredLanguages: {
        var filter = root.languageFilter.trim().toLowerCase()
        var list = root.languages || []
        if (filter.length === 0)
            return list
        return list.filter(function (name) {
            return String(name).toLowerCase().indexOf(filter) >= 0
        })
    }

    readonly property color ink: "#e6ebf0"
    readonly property color ink2: "#aeb8c3"
    readonly property color muted: "#7b8794"
    readonly property color line: "#14e6ebf0"
    readonly property color line2: "#29e6ebf0"
    readonly property color glass: "#b31e2732"
    readonly property color accent: "#7f92cc"
    readonly property color okColor: "#6fd0a3"
    readonly property color failColor: "#f27d93"

    readonly property string serifFamily: serifFont.status === FontLoader.Ready ? serifFont.name : "Georgia"
    readonly property string sansFamily: sansFont.status === FontLoader.Ready ? sansFont.name : "sans-serif"

    property int jobId: 0
    property string requestText: ""

    implicitWidth: 400
    implicitHeight: 900

    // ------------------------------------------------------------------
    // Public helpers (integration and tests)
    // ------------------------------------------------------------------
    function focusComposer() {
        input.forceActiveFocus()
        Qt.callLater(function () {
            if (!input.activeFocus)
                input.forceActiveFocus()
        })
    }

    function translateNow() {
        translateTimer.stop()
        var text = root.inputText.trim()
        if (text.length === 0) {
            root.resetTranslation()
            return
        }

        root.requestText = text
        root.jobId += 1
        root.status = "Translating"
        root.errorText = ""

        if (root.fakeMode) {
            root.stopRequests()
            fakeTimer.restart()
            return
        }

        root.stopRequests()

        if (root.backendIsLocal) {
            root.requestLocalModel(root.jobId)
            return
        }

        // The bridge drives Translate Shell when it is up; otherwise, or if the
        // request fails, the page runs the same command itself.
        if (root.bridgeAvailable)
            root.requestBridgeTranslation(root.jobId)
        else
            root.requestTransProcess(root.jobId)
    }

    function resetTranslation() {
        // Invalidate any request that is still in flight so a late result
        // cannot repopulate the cleared output.
        root.jobId += 1
        root.stopRequests()
        fakeTimer.stop()
        root.translatedText = ""
        root.errorText = ""
        root.status = "Ready"
    }

    // ------------------------------------------------------------------
    // HTTP helpers
    // ------------------------------------------------------------------
    function _postJson(path, payload, callback) {
        var xhr = new XMLHttpRequest()
        var settled = false
        function finish(ok, status, body) {
            if (settled)
                return
            settled = true
            callback(ok, status, body)
        }
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4)
                return
            var body = ""
            try {
                body = xhr.responseText || ""
            } catch (err) {
                body = ""
            }
            finish(xhr.status >= 200 && xhr.status < 300, xhr.status, body)
        }
        xhr.ontimeout = function () { finish(false, 0, "") }
        try {
            xhr.open("POST", root.bridgeBaseUrl + path)
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.timeout = 120000
            xhr.send(JSON.stringify(payload))
        } catch (err) {
            finish(false, 0, "")
        }
        return xhr
    }

    function _parseText(body) {
        try {
            const data = JSON.parse(body)
            return String(data.text || "").trim()
        } catch (err) {
            return ""
        }
    }

    function stopRequests() {
        if (root.translateXhr) {
            try {
                root.translateXhr.abort()
            } catch (err) {
                // already finished
            }
            root.translateXhr = null
        }
        if (translateProc.running)
            translateProc.running = false
        translateProc.buffer = ""
    }

    function translateFailed(message) {
        root.translatedText = ""
        root.errorText = message
        root.status = "Failed"
    }

    function requestLocalModel(job) {
        var xhr = root._postJson("/translate", {
            "text": root.requestText,
            "source": root.sourceLanguage,
            "target": root.targetLanguage,
            "backend": "llama"
        }, function (ok, status, body) {
            if (job !== root.jobId)
                return
            root.translateXhr = null
            if (ok) {
                const out = root._parseText(body)
                if (out.length > 0) {
                    root.translatedText = out
                    root.status = "Ready"
                } else {
                    root.translateFailed("The local model returned an empty translation.")
                }
                return
            }
            if (status === 0) {
                root.translateFailed("Local model unavailable. Start the LFM3 bridge or pick Translate Shell.")
                return
            }
            root.translateFailed("The local model could not translate this text (HTTP " + status + ").")
        })
        root.translateXhr = xhr
    }

    function requestBridgeTranslation(job) {
        var xhr = root._postJson("/translate", {
            "text": root.requestText,
            "source": root.sourceLanguage,
            "target": root.targetLanguage,
            "backend": "trans",
            "engine": root.backend
        }, function (ok, status, body) {
            if (job !== root.jobId)
                return
            root.translateXhr = null
            if (ok) {
                const out = root._parseText(body)
                if (out.length > 0) {
                    root.translatedText = out
                    root.status = "Ready"
                    return
                }
            }
            // The bridge could not run Translate Shell; use the local CLI.
            root.requestTransProcess(job)
        })
        root.translateXhr = xhr
    }

    function requestTransProcess(job) {
        translateProc.running = false
        translateProc.buffer = ""
        translateProc.engine = root.backendIsLocal ? "auto" : root.backend
        translateProc.jobId = job
        translateProc.running = true
    }

    // ------------------------------------------------------------------
    // Models and backend selection
    // ------------------------------------------------------------------
    function formatModelSize(size) {
        var n = Number(size)
        if (!isFinite(n) || n <= 0)
            return String(size || "")
        var units = ["B", "KB", "MB", "GB", "TB"]
        var unit = 0
        while (n >= 1024 && unit < units.length - 1) {
            n /= 1024
            unit += 1
        }
        return (unit >= 3 ? n.toFixed(1) : n.toFixed(0)) + " " + units[unit]
    }

    function refreshModels() {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4)
                return
            var data = null
            if (xhr.status >= 200 && xhr.status < 300) {
                try {
                    data = JSON.parse(xhr.responseText)
                } catch (err) {
                    data = null
                }
            }
            root.bridgeChecked = true
            if (!data) {
                root.bridgeAvailable = false
                return
            }
            root.bridgeAvailable = true
            root.models = Array.isArray(data.models) ? data.models : []
            root.currentModel = data.current || ""
            // The local model is the recommendation as soon as the bridge is up,
            // unless the user already picked a backend.
            if (!root.backendChosen && root.bridgeAvailable && !root.backendIsLocal)
                root.backend = "llama"
        }
        xhr.ontimeout = function () {
            root.bridgeChecked = true
            root.bridgeAvailable = false
        }
        try {
            xhr.open("GET", root.bridgeBaseUrl + "/models")
            xhr.timeout = 4000
            xhr.send()
        } catch (err) {
            root.bridgeChecked = true
            root.bridgeAvailable = false
        }
    }

    function openModelMenu() {
        if (!root.modelMenuOpen)
            root.refreshModels()
        root.modelError = ""
        var origin = modelPill.mapToItem(root, 0, 0)
        root.modelMenuX = Math.max(12, Math.min(origin.x, root.width - root.modelMenuWidth - 12))
        root.modelMenuY = origin.y + modelPill.height + 6
        root.modelMenuOpen = true
        root.backendMenuOpen = false
    }

    function toggleModelMenu() {
        if (!root.bridgeAvailable) {
            root.refreshModels()
            return
        }
        if (root.modelMenuOpen)
            root.modelMenuOpen = false
        else
            root.openModelMenu()
    }

    function chooseModel(id) {
        if (!id || id.length === 0)
            return
        root.currentModel = id
        root.modelMenuOpen = false
        root.modelError = ""
        root._postJson("/model", { "id": id }, function (ok, status, body) {
            if (!ok) {
                root.modelError = "Could not switch the local model."
                root.modelMenuOpen = true
            }
            root.refreshModels()
        })
        Qt.callLater(function () { root.focusComposer() })
    }

    function openBackendMenu() {
        var origin = backendPill.mapToItem(root, 0, 0)
        root.backendMenuX = Math.max(12, Math.min(origin.x, root.width - root.backendMenuWidth - 12))
        root.backendMenuY = origin.y + backendPill.height + 6
        root.backendMenuOpen = true
        root.modelMenuOpen = false
    }

    function toggleBackendMenu() {
        if (root.backendMenuOpen)
            root.backendMenuOpen = false
        else
            root.openBackendMenu()
    }

    function chooseBackend(id) {
        root.backend = id
        root.backendChosen = true
        root.backendMenuOpen = false
        root.errorText = ""
        translateTimer.restart()
        Qt.callLater(function () { root.focusComposer() })
    }

    function closeMenus() {
        var closed = false
        if (root.languageMenuOpen) {
            root.closeLanguageMenu()
            closed = true
        }
        if (root.backendMenuOpen) {
            root.backendMenuOpen = false
            closed = true
        }
        if (root.modelMenuOpen) {
            root.modelMenuOpen = false
            closed = true
        }
        return closed
    }

    function swapLanguages() {
        var previous = root.sourceLanguage
        root.sourceLanguage = root.targetLanguage
        root.targetLanguage = previous
        root.saveLanguages()
        translateTimer.restart()
    }

    function copyTranslation() {
        if (!root.hasOutput)
            return
        Quickshell.clipboardText = root.translatedText
        copiedTimer.restart()
    }

    function searchTranslation() {
        if (!root.hasOutput)
            return
        var base = Qs.Config.options.search.engineBaseUrl
        if (!base || base.length === 0)
            base = "https://duckduckgo.com/?q="
        var url = base + encodeURIComponent(root.translatedText.trim())
        var excluded = Qs.Config.options.search.excludedSites || []
        for (var i = 0; i < excluded.length; ++i)
            url += " -site:" + excluded[i]
        Qt.openUrlExternally(url)
    }

    function saveLanguages() {
        try {
            Qs.Config.options.language.translator.sourceLanguage = root.sourceLanguage
            Qs.Config.options.language.translator.targetLanguage = root.targetLanguage
        } catch (err) {
            console.warn("[lfm3] could not save translator languages:", err)
        }
    }

    function openLanguageMenu(isTarget) {
        root.backendMenuOpen = false
        root.modelMenuOpen = false
        root.languageMenuTarget = isTarget
        root.languageFilter = ""
        root.languageMenuOpen = true
        Qt.callLater(function () {
            filterInput.text = ""
            filterInput.forceActiveFocus()
            var current = root.languageMenuTarget ? root.targetLanguage : root.sourceLanguage
            var index = root.filteredLanguages.indexOf(current)
            if (index >= 0)
                langList.positionViewAtIndex(index, ListView.Center)
        })
    }

    function closeLanguageMenu() {
        if (!root.languageMenuOpen)
            return
        root.languageMenuOpen = false
        root.languageFilter = ""
        root.focusComposer()
    }

    function chooseLanguage(name) {
        if (!name || name.length === 0)
            return
        if (root.languageMenuTarget)
            root.targetLanguage = name
        else
            root.sourceLanguage = name
        root.saveLanguages()
        root.languageMenuOpen = false
        root.languageFilter = ""
        translateTimer.restart()
        root.focusComposer()
    }

    onSourceLanguageChanged: translateTimer.restart()
    onTargetLanguageChanged: translateTimer.restart()

    onTranslatedTextChanged: outputFlick.contentY = 0

    // The sidebar calls focusActiveItem() on open, and the loader sets
    // isCurrentPage when this page becomes the current SwipeView item.
    onIsCurrentPageChanged: {
        if (root.isCurrentPage) {
            root.refreshModels()
            root.focusComposer()
        }
    }

    onActiveFocusChanged: {
        if (root.activeFocus && !root.languageMenuOpen)
            root.focusComposer()
    }

    // ------------------------------------------------------------------
    // Fonts
    // ------------------------------------------------------------------
    FontLoader { id: serifFont; source: "fonts/Newsreader.ttf" }
    FontLoader { id: serifItalicFont; source: "fonts/Newsreader-Italic.ttf" }
    FontLoader { id: sansFont; source: "fonts/SchibstedGrotesk.ttf" }

    // ------------------------------------------------------------------
    // Translation: debounce, `trans`, language list
    // ------------------------------------------------------------------
    Timer {
        id: translateTimer
        interval: root.debounceInterval
        repeat: false
        onTriggered: root.translateNow()
    }

    Timer {
        id: copiedTimer
        interval: 1400
        repeat: false
    }

    Timer {
        id: fakeTimer
        interval: 420
        repeat: false
        onTriggered: {
            root.translatedText = root.fakeTranslation(root.requestText)
            root.status = "Ready"
        }
    }

    // Keep the shared model choice in sync with Intelligence.
    Timer {
        id: modelPollTimer
        interval: 8000
        repeat: true
        running: true
        onTriggered: {
            if (!root.modelMenuOpen)
                root.refreshModels()
        }
    }

    function fakeTranslation(text) {
        // Preview only. Deliberately local and obvious, never a network call.
        return "Translation of: " + text
    }

    Process {
        id: translateProc
        property string engine: "auto"
        command: {
            var args = ["trans", "-brief", "-no-bidi"]
            if (translateProc.engine.length > 0 && translateProc.engine !== "auto")
                args.push("-engine", translateProc.engine)
            args.push("-source", root.sourceLanguage)
            args.push("-target", root.targetLanguage)
            args.push(root.requestText)
            return args
        }
        property string buffer: ""
        property int jobId: 0

        stdout: SplitParser {
            onRead: data => {
                translateProc.buffer += data + "\n"
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (translateProc.jobId !== root.jobId)
                return // a newer request already replaced this one

            var output = translateProc.buffer.trim()
            if (exitCode !== 0 && output.length === 0) {
                root.translateFailed("Translate Shell could not translate this text. Check the network or the language pair.")
                return
            }
            if (output.length === 0) {
                root.translateFailed("Translate Shell returned an empty translation.")
                return
            }
            root.translatedText = output
            root.errorText = ""
            root.status = "Ready"
        }
    }

    Process {
        id: languagesProc
        command: ["trans", "-list-languages", "-no-bidi"]
        running: true
        property var bufferList: []

        stdout: SplitParser {
            onRead: data => {
                var entry = data.trim()
                if (entry.length > 0)
                    languagesProc.bufferList.push(entry)
            }
        }

        onExited: (exitCode, exitStatus) => {
            var list = languagesProc.bufferList
                .filter(function (name) { return name.length > 0 && name !== "auto" })
                .sort(function (a, b) { return a.localeCompare(b) })
            list.unshift("auto")
            if (list.length > 1)
                root.languages = list
            languagesProc.bufferList = []
        }
    }

    // ------------------------------------------------------------------
    // Inline glyphs: the stroke icons used by the Space panels
    // ------------------------------------------------------------------
    component Glyph: Item {
        id: glyph

        property string kind: "copy"
        property color color: "#aeb8c3"
        property real weight: 1.8

        implicitWidth: 20
        implicitHeight: 20

        readonly property var paths: {
            switch (glyph.kind) {
            case "copy":
                return ["M9 9h10v11H9z", "M6 15.5H4.5V4.5h10V6"]
            case "search":
                return ["M12 3.2a8.8 8.8 0 1 0 0 17.6a8.8 8.8 0 1 0 0-17.6",
                        "M3.4 12h17.2",
                        "M12 3.2c2.4 2.4 3.6 5.4 3.6 8.8s-1.2 6.4-3.6 8.8c-2.4-2.4-3.6-5.4-3.6-8.8S9.6 5.6 12 3.2"]
            case "swap":
                return ["M7 8h10M14 5l3 3-3 3", "M17 16H7M10 13l-3 3 3 3"]
            case "close":
                return ["M6 6l12 12M18 6 6 18"]
            case "chevron-down":
                return ["m6 9 6 6 6-6"]
            case "check":
                return ["M5 12.5l4.5 4.5L19 6.5"]
            case "paste":
                return ["M9 5.5h6v2H9z", "M8.5 5.5h-3v15h13v-15h-2"]
            default:
                return []
            }
        }

        Item {
            anchors.centerIn: parent
            width: 24
            height: 24
            scale: glyph.width / 24

            Repeater {
                model: glyph.paths

                delegate: Shape {
                    required property string modelData

                    width: 24
                    height: 24
                    antialiasing: true

                    ShapePath {
                        strokeColor: glyph.color
                        strokeWidth: glyph.weight
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        joinStyle: ShapePath.RoundJoin
                        PathSvg { path: modelData }
                    }
                }
            }
        }
    }

    // Language pill. Values are explicit so the inline component needs no
    // access to the page ids.
    component LangPill: Rectangle {
        id: pill

        property string caption: "FROM"
        property string value: "auto"
        property bool active: false
        property string family: "sans-serif"

        signal tapped()

        height: 30
        radius: 15
        color: pill.active || pillHover.containsMouse ? "#b326303d" : "#b31e2732"
        border.width: 1
        border.color: pill.active ? "#40ffffff" : "#14e6ebf0"
        Behavior on border.color { ColorAnimation { duration: 180 } }

        Text {
            id: captionText
            anchors {
                left: parent.left
                leftMargin: 11
                verticalCenter: parent.verticalCenter
            }
            text: pill.caption
            color: "#7b8794"
            font.family: pill.family
            font.pixelSize: 9
            font.letterSpacing: 0.9
            font.capitalization: Font.AllUppercase
        }

        Text {
            anchors {
                left: captionText.right
                leftMargin: 6
                right: chevron.left
                rightMargin: 4
                verticalCenter: parent.verticalCenter
            }
            text: pill.value
            color: "#e6ebf0"
            font.family: pill.family
            font.pixelSize: 12
            font.weight: Font.DemiBold
            elide: Text.ElideRight
        }

        Glyph {
            id: chevron
            anchors {
                right: parent.right
                rightMargin: 9
                verticalCenter: parent.verticalCenter
            }
            width: 11
            height: 11
            kind: "chevron-down"
            color: "#aeb8c3"
        }

        MouseArea {
            id: pillHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pill.tapped()
        }
    }

    // ------------------------------------------------------------------
    // Stage
    // ------------------------------------------------------------------
    Rectangle {
        anchors.fill: parent
        color: "#f2121922"
    }

    // Static top glow: depth without an orb or a shader.
    Rectangle {
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
        }
        height: 220
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#121f2a36" }
            GradientStop { position: 1.0; color: "#00121f2a" }
        }
    }

    // ------------------------------------------------------------------
    // Header: model pill, language pills, backend pill
    // ------------------------------------------------------------------
    Item {
        id: header
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
            topMargin: 10
            leftMargin: root.contentPadding
            rightMargin: root.contentPadding
        }
        height: 30 + 6 + 30 + 6 + 30

        // Model pill: the same Intelligence model, shared through the bridge.
        Item {
            id: modelRow
            width: parent.width
            height: 30

            Rectangle {
                id: modelPill
                anchors {
                    left: parent.left
                    verticalCenter: parent.verticalCenter
                }
                width: Math.min(230, root.width * 0.62)
                height: 30
                radius: 15
                color: root.modelMenuOpen ? "#eb26303d" : root.glass
                border.width: 1
                border.color: root.modelMenuOpen ? "#40ffffff" : root.line
                Behavior on border.color { ColorAnimation { duration: 180 } }

                Row {
                    id: modelPillRow
                    anchors {
                        left: parent.left
                        leftMargin: 11
                        right: modelChevron.left
                        rightMargin: 5
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: 6

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 5
                        height: 5
                        radius: 2.5
                        color: root.okColor
                        opacity: root.currentModelLoaded ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                    }

                    Text {
                        width: modelPillRow.width - 11
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.modelPillText
                        color: root.bridgeAvailable ? root.ink : root.muted
                        font.family: root.sansFamily
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                }

                Glyph {
                    id: modelChevron
                    anchors {
                        right: parent.right
                        rightMargin: 10
                        verticalCenter: parent.verticalCenter
                    }
                    width: 11
                    height: 11
                    kind: "chevron-down"
                    color: root.ink2
                    rotation: root.modelMenuOpen ? 180 : 0
                    Behavior on rotation { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                }

                MouseArea {
                    id: modelPillHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleModelMenu()
                }
            }

            Text {
                anchors {
                    left: modelPill.right
                    leftMargin: 9
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                }
                visible: root.bridgeChecked && !root.bridgeAvailable
                text: "Translate Shell ready"
                color: root.muted
                font.family: root.sansFamily
                font.pixelSize: 10
                elide: Text.ElideRight
            }
        }

        Item {
            id: languageRow
            anchors {
                top: modelRow.bottom
                topMargin: 6
                left: parent.left
                right: parent.right
            }
            height: 30

            property real pillWidth: Math.floor((width - 28 - 12) / 2)

            LangPill {
                id: sourcePill
                width: languageRow.pillWidth
                anchors {
                    left: parent.left
                    verticalCenter: parent.verticalCenter
                }
                caption: "FROM"
                value: root.sourceLanguage
                active: root.languageMenuOpen && !root.languageMenuTarget
                family: root.sansFamily
                onTapped: root.openLanguageMenu(false)
            }

            Rectangle {
                id: swapButton
                anchors {
                    left: sourcePill.right
                    leftMargin: 6
                    verticalCenter: parent.verticalCenter
                }
                width: 28
                height: 28
                radius: 14
                color: swapHover.containsMouse ? "#16ffffff" : "transparent"
                border.width: 1
                border.color: swapHover.containsMouse ? root.line2 : "transparent"

                Glyph {
                    anchors.centerIn: parent
                    width: 15
                    height: 15
                    kind: "swap"
                    color: swapHover.containsMouse ? root.ink : root.ink2
                }

                MouseArea {
                    id: swapHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.swapLanguages()
                }
            }

            LangPill {
                id: targetPill
                width: languageRow.pillWidth
                anchors {
                    left: swapButton.right
                    leftMargin: 6
                    verticalCenter: parent.verticalCenter
                }
                caption: "TO"
                value: root.targetLanguage
                active: root.languageMenuOpen && root.languageMenuTarget
                family: root.sansFamily
                onTapped: root.openLanguageMenu(true)
            }
        }

        Item {
            id: backendRow
            anchors {
                top: languageRow.bottom
                topMargin: 6
                left: parent.left
                right: parent.right
            }
            height: 30

            Rectangle {
                id: backendPill
                anchors {
                    left: parent.left
                    verticalCenter: parent.verticalCenter
                }
                width: Math.min(parent.width, backendPillRow.implicitWidth + 40)
                height: 30
                radius: 15
                color: root.backendMenuOpen ? "#eb26303d" : root.glass
                border.width: 1
                border.color: root.backendMenuOpen ? "#40ffffff" : root.line
                Behavior on border.color { ColorAnimation { duration: 180 } }

                Row {
                    id: backendPillRow
                    anchors {
                        left: parent.left
                        leftMargin: 11
                        right: backendChevron.left
                        rightMargin: 4
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: 6

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "ENGINE"
                        color: root.muted
                        font.family: root.sansFamily
                        font.pixelSize: 9
                        font.letterSpacing: 0.9
                        font.capitalization: Font.AllUppercase
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.backendLabel
                        color: root.ink
                        font.family: root.sansFamily
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.backendIsLocal && root.bridgeAvailable
                        width: 5
                        height: 5
                        radius: 2.5
                        color: root.okColor
                    }
                }

                Glyph {
                    id: backendChevron
                    anchors {
                        right: parent.right
                        rightMargin: 9
                        verticalCenter: parent.verticalCenter
                    }
                    width: 11
                    height: 11
                    kind: "chevron-down"
                    color: root.ink2
                    rotation: root.backendMenuOpen ? 180 : 0
                    Behavior on rotation { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleBackendMenu()
                }
            }

            Text {
                anchors {
                    left: backendPill.right
                    leftMargin: 9
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                }
                text: root.backendIsLocal
                      ? (root.bridgeAvailable ? "Recommended" : "Bridge unavailable")
                      : (root.bridgeAvailable ? "via bridge" : "local CLI")
                color: root.backendIsLocal && !root.bridgeAvailable ? root.failColor : root.muted
                font.family: root.sansFamily
                font.pixelSize: 10
                elide: Text.ElideRight
            }
        }
    }

    // ------------------------------------------------------------------
    // Body: translated text, scrollable; label and status stay put
    // ------------------------------------------------------------------
    Item {
        id: body
        anchors {
            top: header.bottom
            topMargin: 12
            left: parent.left
            right: parent.right
            bottom: dock.top
            bottomMargin: 4
            leftMargin: root.contentPadding
            rightMargin: root.contentPadding
        }
        clip: true

        Item {
            id: bodyLabel
            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
            }
            height: 18

            Text {
                anchors {
                    left: parent.left
                    verticalCenter: parent.verticalCenter
                }
                text: "Translation"
                color: root.muted
                font.family: root.sansFamily
                font.pixelSize: 9
                font.letterSpacing: 1.2
                font.capitalization: Font.AllUppercase
            }

            Row {
                anchors {
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                }
                spacing: 5

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 5
                    height: 5
                    radius: 2.5
                    color: root.failed ? root.failColor
                                   : (root.busy ? root.accent : root.okColor)
                    opacity: root.hasOutput || root.busy || root.failed ? 1 : 0.4
                    Behavior on color { ColorAnimation { duration: 250 } }

                    SequentialAnimation on opacity {
                        running: root.busy
                        loops: Animation.Infinite
                        NumberAnimation { from: 0.85; to: 0.25; duration: 620; easing.type: Easing.InOutQuad }
                        NumberAnimation { from: 0.25; to: 0.85; duration: 620; easing.type: Easing.InOutQuad }
                    }
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.failed ? "Failed"
                          : (root.busy ? "Translating" : (root.hasOutput ? "Ready" : "Auto"))
                    color: root.muted
                    font.family: root.sansFamily
                    font.pixelSize: 10
                }
            }
        }

        Flickable {
            id: outputFlick
            anchors {
                top: bodyLabel.bottom
                topMargin: 6
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            contentWidth: width
            contentHeight: outputColumn.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            Column {
                id: outputColumn
                width: outputFlick.width - 14
                spacing: 10

                Text {
                    id: outputText
                    width: parent.width
                    visible: root.hasOutput
                    text: root.translatedText
                    color: root.ink
                    font.family: root.serifFamily
                    font.pixelSize: 24
                    font.weight: Font.Normal
                    font.letterSpacing: -0.2
                    lineHeight: 1.28
                    lineHeightMode: Text.ProportionalHeight
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    opacity: 0

                    onTextChanged: reveal.restart()
                    Component.onCompleted: reveal.start()

                    SequentialAnimation {
                        id: reveal
                        NumberAnimation {
                            target: outputText
                            property: "opacity"
                            from: 0
                            to: 1
                            duration: 320
                            easing.type: Easing.OutCubic
                        }
                    }
                }

                Text {
                    visible: root.failed
                    width: parent.width
                    text: root.errorText.length > 0 ? root.errorText
                                                      : "Translation failed. Check the network or the language pair."
                    color: root.failColor
                    font.family: root.sansFamily
                    font.pixelSize: 11
                    lineHeight: 1.3
                    lineHeightMode: Text.ProportionalHeight
                    wrapMode: Text.Wrap
                }
            }
        }

        // Thin scroll indicator, drawn only when the output overflows.
        Rectangle {
            visible: outputFlick.contentHeight > outputFlick.height + 1
            width: 2
            radius: 1
            color: "#33e6ebf0"
            x: parent.width - 3
            height: Math.max(24, outputFlick.height * outputFlick.height
                             / Math.max(1, outputFlick.contentHeight))
            y: outputFlick.y + Math.max(0, (outputFlick.height - height)
                * (outputFlick.contentY / Math.max(1, outputFlick.contentHeight - outputFlick.height)))
            Behavior on y { NumberAnimation { duration: 90 } }
        }

        // Empty states, centred in the free area.
        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - 32, 300)
            spacing: 8
            visible: !root.hasOutput && !root.busy && !root.failed

            Text {
                width: parent.width
                text: root.hasInput ? "Translating…" : "Type to translate."
                color: root.hasInput ? root.muted : root.ink
                font.family: root.serifFamily
                font.pixelSize: root.hasInput ? 20 : 27
                font.weight: Font.Light
                lineHeight: 1.12
                lineHeightMode: Text.ProportionalHeight
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
            }

            Text {
                width: parent.width
                visible: !root.hasInput
                text: root.backendIsLocal
                      ? "Pick a language pair above. Text stays on this machine."
                      : "Pick a language pair above. Translate Shell uses the selected engine."
                color: root.muted
                font.family: root.sansFamily
                font.pixelSize: 12
                lineHeight: 1.35
                lineHeightMode: Text.ProportionalHeight
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
            }
        }

        // Busy state with no output yet.
        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - 32, 300)
            spacing: 8
            visible: root.busy && !root.hasOutput

            Text {
                width: parent.width
                text: "Translating…"
                color: root.muted
                font.family: root.serifFamily
                font.italic: true
                font.pixelSize: 20
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
            }
        }
    }

    // ------------------------------------------------------------------
    // Dock: actions, glass composer, hint
    // ------------------------------------------------------------------
    Item {
        id: dock
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        height: actionBar.height + composer.height + hint.height + 32

        Row {
            id: actionBar
            anchors {
                top: parent.top
                horizontalCenter: parent.horizontalCenter
            }
            width: parent.width - 32
            height: 26
            spacing: 8

            Rectangle {
                width: copyRow.implicitWidth + 20
                height: 26
                radius: 13
                color: copyHover.containsMouse && root.hasOutput ? "#14ffffff" : "transparent"
                border.width: 1
                border.color: root.line2
                opacity: root.hasOutput ? 1 : 0.4
                Behavior on opacity { NumberAnimation { duration: 180 } }

                Row {
                    id: copyRow
                    anchors.centerIn: parent
                    spacing: 6

                    Glyph {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 13
                        height: 13
                        kind: copiedTimer.running ? "check" : "copy"
                        color: root.hasOutput ? root.ink2 : root.muted
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: copiedTimer.running ? "Copied" : "Copy"
                        color: root.hasOutput ? root.ink2 : root.muted
                        font.family: root.sansFamily
                        font.pixelSize: 11
                    }
                }

                MouseArea {
                    id: copyHover
                    anchors.fill: parent
                    enabled: root.hasOutput
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.copyTranslation()
                }
            }

            Rectangle {
                width: searchRow.implicitWidth + 20
                height: 26
                radius: 13
                color: searchHover.containsMouse && root.hasOutput ? "#14ffffff" : "transparent"
                border.width: 1
                border.color: root.line2
                opacity: root.hasOutput ? 1 : 0.4
                Behavior on opacity { NumberAnimation { duration: 180 } }

                Row {
                    id: searchRow
                    anchors.centerIn: parent
                    spacing: 6

                    Glyph {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 13
                        height: 13
                        kind: "search"
                        color: root.hasOutput ? root.ink2 : root.muted
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Search"
                        color: root.hasOutput ? root.ink2 : root.muted
                        font.family: root.sansFamily
                        font.pixelSize: 11
                    }
                }

                MouseArea {
                    id: searchHover
                    anchors.fill: parent
                    enabled: root.hasOutput
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.searchTranslation()
                }
            }
        }

        Rectangle {
            id: composer
            anchors {
                top: actionBar.bottom
                topMargin: 8
                horizontalCenter: parent.horizontalCenter
            }
            width: parent.width - 24
            height: Math.max(52, Math.min(132, input.contentHeight + 32))
            radius: 26
            color: root.glass
            border.width: 1
            border.color: input.activeFocus ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.55) : root.line
            Behavior on border.color { ColorAnimation { duration: 250 } }
            Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

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

            Item {
                id: field
                anchors {
                    left: parent.left
                    right: tools.left
                    top: parent.top
                    bottom: parent.bottom
                    leftMargin: 17
                    rightMargin: 6
                }

                TapHandler {
                    onTapped: root.focusComposer()
                }

                Text {
                    anchors.fill: parent
                    anchors.topMargin: 15
                    text: "Type to translate…"
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
                    selectionColor: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.45)
                    selectedTextColor: root.ink
                    font.family: root.sansFamily
                    font.pixelSize: 15
                    wrapMode: TextEdit.Wrap
                    selectByMouse: true
                    activeFocusOnPress: true
                    clip: true
                    cursorVisible: text.length > 0
                    focus: false

                    onTextChanged: translateTimer.restart()

                    Keys.onPressed: (event) => {
                        if (event.key === Qt.Key_Escape) {
                            if (root.closeMenus())
                                event.accepted = true
                            return
                        }
                        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                && (event.modifiers & Qt.ControlModifier)) {
                            event.accepted = true
                            root.translateNow()
                            return
                        }
                    }
                }
            }

            Row {
                id: tools
                anchors {
                    right: parent.right
                    rightMargin: 10
                    bottom: parent.bottom
                    bottomMargin: 11
                }
                spacing: 2

                Rectangle {
                    width: 28
                    height: 28
                    radius: 14
                    color: pasteHover.containsMouse ? "#16ffffff" : "transparent"

                    Glyph {
                        anchors.centerIn: parent
                        width: 15
                        height: 15
                        kind: "paste"
                        color: pasteHover.containsMouse ? root.ink : root.ink2
                    }

                    MouseArea {
                        id: pasteHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.inputText = Quickshell.clipboardText
                            root.focusComposer()
                        }
                    }
                }

                Rectangle {
                    width: 28
                    height: 28
                    radius: 14
                    color: clearHover.containsMouse ? "#16ffffff" : "transparent"
                    opacity: root.hasInput ? 1 : 0.4
                    Behavior on opacity { NumberAnimation { duration: 160 } }

                    Glyph {
                        anchors.centerIn: parent
                        width: 14
                        height: 14
                        kind: "close"
                        color: clearHover.containsMouse && root.hasInput ? root.ink : root.ink2
                    }

                    MouseArea {
                        id: clearHover
                        anchors.fill: parent
                        enabled: root.hasInput
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.inputText = ""
                            root.resetTranslation()
                            root.focusComposer()
                        }
                    }
                }
            }
        }

        Text {
            id: hint
            anchors {
                top: composer.bottom
                topMargin: 6
                horizontalCenter: parent.horizontalCenter
            }
            text: root.busy ? "Translating as you type."
                  : (root.failed ? "Escape closes the picker."
                     : "Auto-translates · Ctrl+Enter now · Esc closes the picker")
            color: root.muted
            font.family: root.sansFamily
            font.pixelSize: 10
            horizontalAlignment: Text.AlignHCenter
            Behavior on color { ColorAnimation { duration: 250 } }
        }
    }

    // ------------------------------------------------------------------
    // Model menu: glass dropdown under the pill, same shape as Intelligence
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
            height: modelMenuColumn.implicitHeight + 16
            radius: 14
            color: "#f21e2732"
            border.width: 1
            border.color: root.line2

            // Swallow clicks on the panel so only the scrim closes it.
            MouseArea { anchors.fill: parent }

            Column {
                id: modelMenuColumn
                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                    margins: 8
                }
                spacing: 2

                Item {
                    width: parent.width
                    height: 24

                    Text {
                        anchors {
                            left: parent.left
                            leftMargin: 4
                            verticalCenter: parent.verticalCenter
                        }
                        text: "Models"
                        color: root.muted
                        font.family: root.sansFamily
                        font.pixelSize: 10
                        font.letterSpacing: 1.0
                        font.capitalization: Font.AllUppercase
                    }

                    Text {
                        anchors {
                            right: parent.right
                            rightMargin: 4
                            verticalCenter: parent.verticalCenter
                        }
                        text: (root.models ? root.models.length : 0) === 1
                              ? "1 model"
                              : (root.models ? root.models.length : 0) + " models"
                        color: root.muted
                        font.family: root.sansFamily
                        font.pixelSize: 10
                    }
                }

                Repeater {
                    model: root.models

                    delegate: Rectangle {
                        id: modelRowItem
                        required property var modelData

                        width: modelMenuColumn.width
                        height: 46
                        radius: 9
                        color: modelRowHover.containsMouse ? "#16ffffff"
                               : (modelData.id === root.currentModel ? "#0cffffff" : "transparent")

                        Rectangle {
                            anchors {
                                left: parent.left
                                leftMargin: 10
                                verticalCenter: parent.verticalCenter
                            }
                            visible: modelData.loaded === true
                            width: 6
                            height: 6
                            radius: 3
                            color: root.okColor
                        }

                        Column {
                            anchors {
                                left: parent.left
                                leftMargin: 24
                                right: modelCheck.left
                                rightMargin: 6
                                verticalCenter: parent.verticalCenter
                            }
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
                                text: root.formatModelSize(modelData.size)
                                color: root.muted
                                font.family: root.sansFamily
                                font.pixelSize: 10
                                elide: Text.ElideRight
                            }
                        }

                        Glyph {
                            id: modelCheck
                            anchors {
                                right: parent.right
                                rightMargin: 10
                                verticalCenter: parent.verticalCenter
                            }
                            width: 13
                            height: 13
                            kind: "check"
                            color: root.ink
                            visible: modelData.id === root.currentModel
                        }

                        MouseArea {
                            id: modelRowHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.chooseModel(modelData.id)
                        }
                    }
                }

                Text {
                    width: parent.width
                    height: 40
                    visible: root.models.length === 0
                    text: root.bridgeAvailable ? "No models found" : "Bridge unavailable"
                    color: root.muted
                    font.family: root.sansFamily
                    font.pixelSize: 11
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    wrapMode: Text.Wrap
                }

                Text {
                    width: parent.width
                    height: 28
                    visible: root.modelError.length > 0
                    text: root.modelError
                    color: root.failColor
                    font.family: root.sansFamily
                    font.pixelSize: 10
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    wrapMode: Text.Wrap
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Backend menu: Local LFM3 or a Translate Shell engine
    // ------------------------------------------------------------------
    Item {
        id: backendMenuLayer
        anchors.fill: parent
        z: 150
        visible: root.backendMenuOpen

        Rectangle {
            anchors.fill: parent
            color: "#18000000"
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.backendMenuOpen = false
        }

        Rectangle {
            id: backendMenu
            x: root.backendMenuX
            y: root.backendMenuY
            width: root.backendMenuWidth
            height: backendMenuColumn.implicitHeight + 16
            radius: 14
            color: "#f21e2732"
            border.width: 1
            border.color: root.line2

            MouseArea { anchors.fill: parent }

            Column {
                id: backendMenuColumn
                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                    margins: 8
                }
                spacing: 2

                Item {
                    width: parent.width
                    height: 24

                    Text {
                        anchors {
                            left: parent.left
                            leftMargin: 4
                            verticalCenter: parent.verticalCenter
                        }
                        text: "Translate with"
                        color: root.muted
                        font.family: root.sansFamily
                        font.pixelSize: 10
                        font.letterSpacing: 1.0
                        font.capitalization: Font.AllUppercase
                    }
                }

                Repeater {
                    model: root.backendOptions

                    delegate: Rectangle {
                        id: backendRowItem
                        required property var modelData

                        width: backendMenuColumn.width
                        height: 46
                        radius: 9
                        color: backendRowHover.containsMouse ? "#16ffffff"
                               : (modelData.id === root.backend ? "#0cffffff" : "transparent")

                        Rectangle {
                            anchors {
                                left: parent.left
                                leftMargin: 10
                                verticalCenter: parent.verticalCenter
                            }
                            visible: modelData.id === "llama" && root.bridgeAvailable
                            width: 6
                            height: 6
                            radius: 3
                            color: root.okColor
                        }

                        Column {
                            anchors {
                                left: parent.left
                                leftMargin: 24
                                right: backendCheck.left
                                rightMargin: 6
                                verticalCenter: parent.verticalCenter
                            }
                            spacing: 1

                            Text {
                                width: parent.width
                                text: modelData.title
                                color: root.ink
                                font.family: root.sansFamily
                                font.pixelSize: 13
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                            }

                            Text {
                                width: parent.width
                                text: modelData.recommended
                                      ? (modelData.detail.length > 0
                                         ? modelData.detail + " \u00b7 recommended"
                                         : "recommended")
                                      : modelData.detail
                                visible: text.length > 0
                                color: modelData.recommended ? root.okColor : root.muted
                                font.family: root.sansFamily
                                font.pixelSize: 10
                                elide: Text.ElideRight
                            }
                        }

                        Glyph {
                            id: backendCheck
                            anchors {
                                right: parent.right
                                rightMargin: 10
                                verticalCenter: parent.verticalCenter
                            }
                            width: 13
                            height: 13
                            kind: "check"
                            color: root.ink
                            visible: modelData.id === root.backend
                        }

                        MouseArea {
                            id: backendRowHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.chooseBackend(modelData.id)
                        }
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Language picker: glass sheet, filter, Escape closes
    // ------------------------------------------------------------------
    Item {
        id: languageLayer
        anchors.fill: parent
        z: 200
        visible: opacity > 0.01
        opacity: root.languageMenuOpen ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }

        Rectangle {
            anchors.fill: parent
            color: "#66000000"
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.closeLanguageMenu()
        }

        Rectangle {
            id: languagePanel
            anchors {
                fill: parent
                topMargin: 46
                bottomMargin: 16
                leftMargin: 12
                rightMargin: 12
            }
            radius: 16
            color: "#f21e2732"
            border.width: 1
            border.color: root.line2
            scale: root.languageMenuOpen ? 1 : 0.98
            Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            // Swallow clicks on the panel so only the scrim closes it.
            MouseArea { anchors.fill: parent }

            Item {
                id: languageHead
                anchors {
                    top: parent.top
                    left: parent.left
                    right: parent.right
                    topMargin: 6
                    leftMargin: 16
                    rightMargin: 10
                }
                height: 40

                Text {
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                    }
                    text: root.languageMenuTarget ? "Translate to" : "Translate from"
                    color: root.ink
                    font.family: root.serifFamily
                    font.italic: true
                    font.pixelSize: 21
                }

                Rectangle {
                    anchors {
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                    }
                    width: 26
                    height: 26
                    radius: 13
                    color: pickerCloseHover.containsMouse ? "#14ffffff" : "transparent"

                    Glyph {
                        anchors.centerIn: parent
                        width: 15
                        height: 15
                        kind: "close"
                        color: pickerCloseHover.containsMouse ? root.ink : root.ink2
                    }

                    MouseArea {
                        id: pickerCloseHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.closeLanguageMenu()
                    }
                }
            }

            Rectangle {
                id: filterBox
                anchors {
                    top: languageHead.bottom
                    topMargin: 6
                    left: parent.left
                    right: parent.right
                    leftMargin: 14
                    rightMargin: 14
                }
                height: 34
                radius: 17
                color: "#0fffffff"
                border.width: 1
                border.color: filterInput.activeFocus ? "#40ffffff" : root.line

                Text {
                    anchors {
                        left: parent.left
                        leftMargin: 14
                        verticalCenter: parent.verticalCenter
                    }
                    text: "Filter languages"
                    visible: filterInput.text.length === 0
                    color: root.muted
                    font.family: root.sansFamily
                    font.pixelSize: 12
                }

                TextInput {
                    id: filterInput
                    anchors {
                        fill: parent
                        leftMargin: 14
                        rightMargin: 14
                    }
                    verticalAlignment: TextInput.AlignVCenter
                    color: root.ink
                    selectionColor: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.45)
                    selectedTextColor: root.ink
                    font.family: root.sansFamily
                    font.pixelSize: 12
                    selectByMouse: true

                    onTextChanged: root.languageFilter = text

                    Keys.onPressed: (event) => {
                        if (event.key === Qt.Key_Escape) {
                            event.accepted = true
                            root.closeLanguageMenu()
                        } else if (event.key === Qt.Key_Down) {
                            event.accepted = true
                            langList.forceActiveFocus()
                            if (langList.currentIndex < 0)
                                langList.currentIndex = 0
                        }
                    }
                }
            }

            ListView {
                id: langList
                anchors {
                    top: filterBox.bottom
                    topMargin: 8
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                    leftMargin: 8
                    rightMargin: 8
                    bottomMargin: 8
                }
                model: root.filteredLanguages
                clip: true
                spacing: 0
                boundsBehavior: Flickable.StopAtBounds
                currentIndex: -1

                Keys.onPressed: (event) => {
                    if (event.key === Qt.Key_Escape) {
                        event.accepted = true
                        root.closeLanguageMenu()
                    } else if (event.key === Qt.Key_Up && currentIndex <= 0) {
                        event.accepted = true
                        filterInput.forceActiveFocus()
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        event.accepted = true
                        if (currentIndex >= 0 && currentIndex < root.filteredLanguages.length)
                            root.chooseLanguage(root.filteredLanguages[currentIndex])
                    }
                }

                delegate: Rectangle {
                    id: langRow
                    required property string modelData

                    width: langList.width
                    height: 40
                    radius: 9
                    color: rowHover.containsMouse ? "#16ffffff"
                           : (rowSelected ? "#0cffffff" : "transparent")

                    property bool rowSelected: modelData === (root.languageMenuTarget
                                                              ? root.targetLanguage
                                                              : root.sourceLanguage)

                    Text {
                        anchors {
                            left: parent.left
                            leftMargin: 12
                            right: checkGlyph.left
                            rightMargin: 8
                            verticalCenter: parent.verticalCenter
                        }
                        text: modelData
                        color: langRow.rowSelected ? root.ink : root.ink2
                        font.family: root.sansFamily
                        font.pixelSize: 13
                        horizontalAlignment: Text.AlignLeft
                        elide: Text.ElideRight
                    }

                    Glyph {
                        id: checkGlyph
                        anchors {
                            right: parent.right
                            rightMargin: 12
                            verticalCenter: parent.verticalCenter
                        }
                        width: 13
                        height: 13
                        kind: "check"
                        color: root.ink
                        visible: langRow.rowSelected
                    }

                    MouseArea {
                        id: rowHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.chooseLanguage(modelData)
                    }
                }

                Text {
                    anchors.centerIn: parent
                    width: parent.width - 40
                    visible: langList.count === 0
                    text: "No language matches that filter."
                    color: root.muted
                    font.family: root.serifFamily
                    font.italic: true
                    font.pixelSize: 17
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Keyboard
    // ------------------------------------------------------------------
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) {
            if (root.closeMenus())
                event.accepted = true
            return
        }
        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                && (event.modifiers & Qt.ControlModifier)) {
            event.accepted = true
            root.translateNow()
        }
    }

    // Focus is not requested on load: the sidebar creates every page, and the
    // page must not steal focus from the active tab.
    Component.onCompleted: {
        root.refreshModels()
        if (root.isCurrentPage && root.activeFocus)
            root.focusComposer()
    }
}
