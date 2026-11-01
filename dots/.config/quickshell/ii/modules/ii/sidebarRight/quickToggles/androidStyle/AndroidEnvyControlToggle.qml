import qs.modules.common
import qs.modules.common.models.quickToggles
import qs.modules.common.widgets
import qs.services
import QtQuick
import Quickshell
import Quickshell.Io

// GPU mode toggle (envycontrol) for the ii panel android-style quick toggles.
AndroidQuickToggleButton {
    id: root

    toggleModel: EnvyControlToggle {}
}
