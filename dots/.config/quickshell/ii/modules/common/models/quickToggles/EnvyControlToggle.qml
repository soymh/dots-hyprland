import QtQuick
import Quickshell
import Quickshell.Io

// GPU mode toggle via envycontrol (extension repo, not part of upstream illogical-impulse)
QuickToggleModel {
    id: root

    readonly property string scriptPath: "/home/soymh/.config/hypr/custom/scripts/gpu-switch.sh"
    readonly property bool hybrid: mode === "hybrid"

    property string mode: "integrated"

    name: "GPU Mode"
    statusText: hybrid ? "Hybrid · dGPU on" : "Integrated · iGPU only"
    icon: hybrid ? "developer_board" : "memory"
    tooltipText: "envycontrol: " + (hybrid ? "Hybrid (dGPU on)" : "Integrated (iGPU only)") + " — click to switch"
    toggled: hybrid

    mainAction: () => {
        Quickshell.execDetached([scriptPath])
    }

    function refresh() {
        queryProc.running = true
    }

    Process {
        id: queryProc
        command: ["bash", "-c", "envycontrol --query 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                const text = this.text.trim().toLowerCase()
                root.available = text.length > 0
                if (text.includes("hybrid"))
                    root.mode = "hybrid"
                else
                    root.mode = "integrated"
            }
        }
    }

    Timer {
        interval: 5000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    Component.onCompleted: refresh()
}
