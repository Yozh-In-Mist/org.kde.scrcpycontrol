// SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick 2.15
import QtQuick.Layouts 1.15

import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.components 3.0 as PlasmaComponents3

PlasmaComponents3.Frame {
    id: root

    Layout.fillWidth: true
    padding: Kirigami.Units.smallSpacing

    property string key: ""
    property string connType: ""
    property var flags: []
    property bool outside: false
    property int pid: -1
    property string displayName: ""
    property string logPath: ""
    property bool logAvailable: false

    signal requestKill(int pid, string key)
    signal requestRename(string key, string newName)
    signal requestShowLogs(string title, string logPath, bool available)

    property bool editing: false
    property string draftName: ""

    function connTypeText() {
        if (connType === "wifi") return i18n("Wi-Fi");
        if (connType === "usb") return i18n("USB");
        return i18n("Unknown");
    }

    function flagsText() {
        if (!flags || flags.length === 0) return i18n("Default");
        return flags.join(" ");
    }

    RowLayout {
        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing

        // Left block: editable display name and immutable runtime metadata.
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Item {
                id: nameSlot

                Layout.fillWidth: true
                implicitHeight: Math.max(nameLabel.implicitHeight, nameEdit.implicitHeight)

                PlasmaComponents3.Label {
                    id: nameLabel

                    anchors.left: parent.left
                    anchors.right: parent.right
                    visible: !root.editing
                    text: root.displayName
                    elide: Text.ElideRight
                }

                PlasmaComponents3.TextField {
                    id: nameEdit

                    anchors.left: parent.left
                    anchors.right: parent.right
                    visible: root.editing
                    text: root.draftName
                    selectByMouse: true
                    onAccepted: saveName()
                    Keys.onEscapePressed: cancelEdit()
                }

                function startEdit() {
                    root.draftName = root.displayName;
                    root.editing = true;
                    nameEdit.forceActiveFocus();
                    nameEdit.selectAll();
                }

                function saveName() {
                    const newName = nameEdit.text;
                    root.editing = false;
                    root.requestRename(root.key, newName);
                }

                function cancelEdit() {
                    root.editing = false;
                }
            }

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                opacity: 0.65
                elide: Text.ElideRight
                text: {
                    const origin = root.outside ? i18n("Outside") : i18n("Widget");
                    return `${root.connTypeText()} • ${origin} • PID ${root.pid} • ${root.flagsText()}`;
                }
            }
        }

        PlasmaComponents3.ToolButton {
            icon.name: root.editing ? "document-save" : "document-edit"
            Accessible.name: root.editing ? i18n("Save name") : i18n("Rename")

            onClicked: {
                if (!root.editing) nameSlot.startEdit();
                else nameSlot.saveName();
            }

            PlasmaComponents3.ToolTip {
                text: root.editing ? i18n("Save instance name") : i18n("Rename instance")
            }
        }

        PlasmaComponents3.ToolButton {
            icon.name: "text-x-generic"
            Accessible.name: i18n("Show logs")
            onClicked: root.requestShowLogs(root.displayName, root.logPath, root.logAvailable)

            PlasmaComponents3.ToolTip {
                text: root.logAvailable
                    ? i18n("Show captured logs for this instance")
                    : i18n("Logs are unavailable for this instance")
            }
        }

        PlasmaComponents3.ToolButton {
            icon.name: "network-disconnect"
            Accessible.name: i18n("Close instance")
            onClicked: root.requestKill(root.pid, root.key)

            PlasmaComponents3.ToolTip {
                text: i18n("Terminate this scrcpy process")
            }
        }
    }
}
