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
    property string deviceState: "unknown"
    property var transports: []
    property string preferredSerial: ""
    property bool isUnknown: false

    property var instances: []
    property var deviceDefaults: ({})

    property bool expandedWanted: false
    property bool createOpenWanted: false

    property bool showCreateInline: false
    property bool hoveredNow: false
    property string selectedTransportSerial: ""

    readonly property var onlineTransports: (transports || []).filter(transport => transport && transport.state === "device")
    readonly property bool canCreateInstance: !isUnknown && onlineTransports.length > 0

    signal expandedStateChanged(string deviceId, bool expanded)
    signal toggleCreateRequested(string deviceId, bool open)
    signal preferredTransportChanged(string deviceId, string serial)

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
        root.showCreateInline = !!createOpenWanted && root.canCreateInstance;
        if (root.showCreateInline && !root.expanded) root.expand();
    }

    function syncSelectedTransport() {
        if (!root.onlineTransports.length) {
            root.selectedTransportSerial = "";
            return;
        }
        if (root.onlineTransports.some(transport => transport.serial === root.preferredSerial)) {
            root.selectedTransportSerial = root.preferredSerial;
            return;
        }
        if (root.onlineTransports.some(transport => transport.serial === root.selectedTransportSerial)) return;
        root.selectedTransportSerial = root.onlineTransports[0].serial;
    }

    function transportName(transport) {
        if (!transport) return i18n("Unknown");
        if (transport.type === "wifi") return i18n("Wi-Fi");
        if (transport.type === "usb") return i18n("USB");
        if (transport.type === "emulator") return i18n("Emulator");
        return i18n("Unknown");
    }

    function transportDisplay(transport) {
        return i18n("%1 — %2", transportName(transport), transport.serial || "");
    }

    function stateText() {
        if (root.isUnknown) return i18n("Instances without a detected device");
        if (root.deviceState === "unauthorized") return i18n("Authorization required on the phone");
        if (root.deviceState === "offline") return i18n("Device is offline");
        if (root.deviceState === "no_permissions") return i18n("No USB permissions for this device");
        if (root.deviceState !== "device") return i18n("Device is unavailable");
        return i18np("%1 instance running", "%1 instances running", root.instances ? root.instances.length : 0);
    }

    onExpandedWantedChanged: applyExpandedWanted()
    onCreateOpenWantedChanged: applyCreateWanted()
    onTransportsChanged: {
        syncSelectedTransport();
        applyCreateWanted();
    }
    onPreferredSerialChanged: syncSelectedTransport()

    Component.onCompleted: {
        syncSelectedTransport();
        applyCreateWanted();
        applyExpandedWanted();
    }

    onExpandedChanged: {
        expandedStateChanged(deviceId, root.expanded);
        if (!root.expanded && root.showCreateInline) toggleCreateRequested(root.deviceId, false);
    }

    icon: root.deviceState === "unauthorized" || root.deviceState === "no_permissions" ? "dialog-warning" : root.iconName
    title: root.titleText
    subtitle: root.stateText()

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
        enabled: root.canCreateInstance
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

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: !root.isUnknown && root.deviceState !== "device"
            type: Kirigami.MessageType.Warning
            text: root.stateText()
        }

        RowLayout {
            Layout.fillWidth: true
            visible: root.onlineTransports.length > 0

            PlasmaComponents3.Label {
                text: i18n("Connection")
                opacity: 0.8
            }

            PlasmaComponents3.ComboBox {
                Layout.fillWidth: true
                visible: root.onlineTransports.length > 1
                model: root.onlineTransports.map(transport => root.transportDisplay(transport))
                currentIndex: {
                    const index = root.onlineTransports.findIndex(transport => transport.serial === root.selectedTransportSerial);
                    return index >= 0 ? index : 0;
                }
                onActivated: {
                    if (currentIndex < 0 || currentIndex >= root.onlineTransports.length) return;
                    root.selectedTransportSerial = root.onlineTransports[currentIndex].serial;
                    root.preferredTransportChanged(root.deviceId, root.selectedTransportSerial);
                }
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                visible: root.onlineTransports.length === 1
                text: root.onlineTransports.length ? root.transportDisplay(root.onlineTransports[0]) : ""
                elide: Text.ElideMiddle
            }
        }

        CreateInstanceRow {
            visible: root.showCreateInline && root.canCreateInstance
            Layout.fillWidth: true

            plasmoidObj: plasmoid
            deviceSerial: root.selectedTransportSerial
            deviceConfigKey: root.deviceId
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
