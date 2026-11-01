// Rich assistant reply for the Intelligence tab: markdown + LaTeX.
//
// Quickshell-side component: it reuses the ii LatexRenderer singleton, the same
// engine behind modules/ii/sidebarLeft/aiChat/MessageTextBlock.qml. The tab
// only creates this when the host sets `richReplyComponent` (see
// IntelligencePage.qml); qml6 previews keep the plain Text fallback.

import QtQuick
import qs.services

Item {
    id: root

    property string text: ""
    property bool done: true
    property color textColor: "#e6ebf0"
    property color linkColor: "#7f92cc"
    property string fontFamily: "Georgia"
    property real pixelSize: 27
    property real lineHeight: 1.22
    property bool dark: true

    implicitHeight: body.implicitHeight

    // Text with LatexRenderer image substitutions, as MessageTextBlock does.
    property string renderedText: ""
    property var renderedHashes: []

    onTextChanged: root.renderLatex()
    onDoneChanged: root.renderLatex()
    Component.onCompleted: root.renderLatex()

    Text {
        id: body
        width: root.width
        text: root.renderedText
        textFormat: Text.MarkdownText
        color: root.textColor
        linkColor: root.linkColor
        font.family: root.fontFamily
        font.pixelSize: root.pixelSize
        font.weight: Font.Normal
        font.letterSpacing: -0.25
        wrapMode: Text.Wrap
        lineHeight: root.lineHeight
        lineHeightMode: Text.ProportionalHeight
        horizontalAlignment: Text.AlignHCenter
        onLinkActivated: (link) => Qt.openUrlExternally(link)
    }

    Connections {
        target: LatexRenderer
        function onRenderFinished(hash, imagePath) {
            if (root.renderedHashes.indexOf(hash) < 0)
                return
            var expression = LatexRenderer.processedExpressions[hash]
            if (!expression)
                return
            var marker = "![latex](" + imagePath + ")"
            if (root.renderedText.indexOf(marker) >= 0)
                return
            root.renderedText = root.renderedText.replace(expression, marker)
        }
    }

    function renderLatex() {
        var source = String(root.text)
        var rendered = source
        // $$...$$, $...$, \[...\], \(...\): the same pattern MessageTextBlock uses.
        var regex = /(\$\$([\s\S]+?)\$\$)|(\$([^\$]+?)\$)|(\\\[((?:.|\n)+?)\\\])|(\\\(([\s\S]+?)\\\))/g
        var match
        while ((match = regex.exec(source)) !== null) {
            var expression = match[1] || match[2] || match[3] || match[4] || match[5] || match[6] || match[7] || match[8]
            if (!expression)
                continue
            var trimmed = expression.trim()
            var hash = Qt.md5(trimmed)
            if (root.renderedHashes.indexOf(hash) < 0)
                root.renderedHashes.push(hash)
            var imagePath = LatexRenderer.renderedImagePaths[hash]
            if (imagePath) {
                rendered = rendered.replace(match[0], "![latex](" + imagePath + ")")
                continue
            }
            LatexRenderer.requestRender(trimmed)
        }
        root.renderedText = rendered
    }
}
