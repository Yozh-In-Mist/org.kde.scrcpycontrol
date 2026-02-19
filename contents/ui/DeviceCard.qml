// SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.components 3.0 as PlasmaComponents3
import org.kde.plasma.extras 2.0 as PlasmaExtras

PlasmaExtras.ExpandableListItem {
    id: root

    width: parent ? parent.width : implicitWidth

    property string deviceId: ""
    property string titleText: ""
    property string iconName: "smartphone"
    property bool isUnknown: false

    property var instances: []
    property var deviceDefaults: ({})

    property bool expandedWanted: false
    property bool createOpenWanted: false

    property bool showCreateInline: false
    property bool hoveredNow: false

    signal expandedStateChanged(string deviceId, bool expanded)
    signal toggleCreateRequested(string deviceId, bool open)

    signal requestKill(int pid, string key)
    signal requestRename(string key, string newName)
    signal requestShowLogs(string title, string logPath, bool available)
    signal requestCreate(string deviceSerial, string name, var args)
    signal requestSaveDefaults(string deviceSerial, var flagsObj)

    function applyExpandedWanted() {
        if (expandedWanted && !root.expanded) {
            root.expand();
        } else if (!expandedWanted && root.expanded) {
            root.collapse();
        }
    }

    function applyCreateWanted() {
        root.showCreateInline = !!createOpenWanted && !isUnknown;
        if (root.showCreateInline && !root.expanded) root.expand();
    }

    onExpandedWantedChanged: applyExpandedWanted()
    onCreateOpenWantedChanged: applyCreateWanted()

    Component.onCompleted: {
        applyCreateWanted();
        applyExpandedWanted();
    }

    onExpandedChanged: {
        expandedStateChanged(deviceId, root.expanded);
        if (!root.expanded && root.showCreateInline) toggleCreateRequested(root.deviceId, false);
    }

    icon: root.iconName
    title: root.titleText
    subtitle: root.isUnknown
        ? i18n("Instances without a detected device")
        : i18n("%1 instance(s) running", root.instances ? root.instances.length : 0)

    HoverHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onHoveredChanged: root.hoveredNow = hovered
    }

    Loader {
        anchors.fill: parent
        active: root.hoveredNow
        asynchronous: true
        z: -1
        sourceComponent: PlasmaExtras.Highlight {
            hovered: true
        }
    }

    // Dedicated action button for per-device instance creation.
    defaultActionButtonAction: Kirigami.Action {
        enabled: !root.isUnknown
        icon.name: "network-connect"
        text: i18n("Create new instance")
        tooltip: root.showCreateInline ? i18n("Hide create form") : i18n("Create a new instance")
        displayHint: Kirigami.DisplayHint.IconOnly

        onTriggered: {
            const open = !root.showCreateInline;
            root.toggleCreateRequested(root.deviceId, open);
            if (open && !root.expanded) root.expand();
        }
    }

    customExpandedViewContent: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        CreateInstanceRow {
            visible: root.showCreateInline && !root.isUnknown
            Layout.fillWidth: true

            plasmoidObj: plasmoid
            deviceSerial: root.deviceId
            defaults: root.deviceDefaults

            onCreateRequested: (device, name, args) => root.requestCreate(device, name, args)
            onSaveDefaultsRequested: (device, flagsObj) => root.requestSaveDefaults(device, flagsObj)
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Repeater {
                model: root.instances || []
                delegate: InstanceRow {
                    Layout.fillWidth: true
                    key: modelData.key
                    connType: modelData.connType
                    flags: modelData.flags
                    outside: modelData.outside
                    pid: modelData.pid
                    displayName: modelData.displayName
                    logPath: modelData.logPath || ""
                    logAvailable: !!modelData.logAvailable

                    onRequestKill: (pid, key) => root.requestKill(pid, key)
                    onRequestRename: (key, newName) => root.requestRename(key, newName)
                    onRequestShowLogs: (title, logPath, available) => root.requestShowLogs(title, logPath, available)
                }
            }

            PlasmaComponents3.Label {
                visible: (root.instances || []).length === 0
                opacity: 0.6
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: i18n("No running instances.")
            }
        }
    }
}
