// SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Controls 2.15 as QQC2

import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.components 3.0 as PlasmaComponents3

import "logic.js" as Logic

QQC2.ScrollView {
    id: root

    required property var adbDevices
    required property bool operationBusy
    required property string statusText
    required property string statusKind
    required property string detailsText

    property int methodIndex: 0
    property string pairingEndpoint: ""
    property string pairingCode: ""
    property string usbSerial: ""
    property string legacyPort: "5555"
    property string manualEndpoint: ""
    property string disconnectSerial: ""
    property bool detailsVisible: false

    readonly property var usbCandidates: (adbDevices || []).filter(device =>
        device && device.state === "device" && Logic.inferConnTypeFromSerial(device.serial) === "usb")
    readonly property var wifiCandidates: (adbDevices || []).filter(device =>
        device && device.state === "device" && Logic.inferConnTypeFromSerial(device.serial) === "wifi")

    signal pairRequested(string endpoint, string pairingCode)
    signal legacySetupRequested(string serial, string port)
    signal manualConnectRequested(string endpoint)
    signal disconnectRequested(string serial)
    signal usbModeRequested(string serial)

    Layout.fillWidth: true
    Layout.fillHeight: true
    clip: true
    QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff

    function reconcileSelections() {
        if (!usbCandidates.some(device => device.serial === usbSerial)) {
            usbSerial = usbCandidates.length ? usbCandidates[0].serial : "";
        }
        if (!wifiCandidates.some(device => device.serial === disconnectSerial)) {
            disconnectSerial = wifiCandidates.length ? wifiCandidates[0].serial : "";
        }
    }

    onAdbDevicesChanged: reconcileSelections()
    onDetailsTextChanged: detailsVisible = false
    Component.onCompleted: reconcileSelections()

    ColumnLayout {
        width: root.availableWidth
        spacing: Kirigami.Units.smallSpacing

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: root.statusText.length > 0
            text: root.statusText
            type: {
                if (root.statusKind === "positive") return Kirigami.MessageType.Positive;
                if (root.statusKind === "warning") return Kirigami.MessageType.Warning;
                if (root.statusKind === "error") return Kirigami.MessageType.Error;
                return Kirigami.MessageType.Information;
            }
        }

        QQC2.ProgressBar {
            Layout.fillWidth: true
            visible: root.operationBusy
            indeterminate: true
        }

        PlasmaComponents3.Frame {
            Layout.fillWidth: true
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    text: i18n("Connection method")
                    font.weight: Font.Medium
                }

                PlasmaComponents3.ComboBox {
                    Layout.fillWidth: true
                    enabled: !root.operationBusy
                    model: [
                        i18n("Wireless debugging (Android 11+)"),
                        i18n("Set up through USB"),
                        i18n("Manual connection")
                    ]
                    currentIndex: root.methodIndex
                    onActivated: root.methodIndex = currentIndex
                }
            }
        }

        StackLayout {
            Layout.fillWidth: true
            currentIndex: root.methodIndex

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: i18n("On the phone, open Developer options → Wireless debugging → Pair device with pairing code. Enter the shown IP address and pairing port below.")
                }

                PlasmaComponents3.Label {
                    text: i18n("Pairing address")
                    opacity: 0.8
                }

                PlasmaComponents3.TextField {
                    Layout.fillWidth: true
                    enabled: !root.operationBusy
                    text: root.pairingEndpoint
                    placeholderText: i18n("192.168.1.20:37123")
                    onTextChanged: root.pairingEndpoint = text.trim()
                }

                PlasmaComponents3.Label {
                    text: i18n("Six-digit pairing code")
                    opacity: 0.8
                }

                RowLayout {
                    Layout.fillWidth: true

                    PlasmaComponents3.TextField {
                        Layout.fillWidth: true
                        enabled: !root.operationBusy
                        echoMode: TextInput.Password
                        maximumLength: 6
                        inputMethodHints: Qt.ImhDigitsOnly
                        text: root.pairingCode
                        placeholderText: i18n("Pairing code")
                        onTextChanged: {
                            const digits = text.replace(/[^0-9]/g, "");
                            if (digits !== text) text = digits;
                            root.pairingCode = digits;
                        }
                    }

                    PlasmaComponents3.Button {
                        text: i18n("Pair")
                        icon.name: "network-connect"
                        enabled: !root.operationBusy
                        onClicked: {
                            const code = root.pairingCode;
                            root.pairingCode = "";
                            root.pairRequested(root.pairingEndpoint, code);
                        }
                    }
                }

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    opacity: 0.7
                    text: i18n("Pairing is normally needed only once. Android should connect automatically afterwards; if it does not, use Manual connection with the address shown on the main Wireless debugging screen.")
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: i18n("Keep the authorized USB cable connected. The widget will detect the phone address, restart ADB in TCP/IP mode, connect and verify the result.")
                }

                PlasmaComponents3.Label {
                    visible: root.usbCandidates.length === 0
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: Kirigami.Theme.neutralTextColor
                    text: i18n("No authorized USB device is available. Connect the phone and accept its USB debugging prompt.")
                }

                RowLayout {
                    Layout.fillWidth: true

                    PlasmaComponents3.ComboBox {
                        Layout.fillWidth: true
                        enabled: root.usbCandidates.length > 0 && !root.operationBusy
                        model: root.usbCandidates.map(device => (device.model ? device.model + " " : "") + "(" + device.serial + ")")
                        currentIndex: {
                            const index = root.usbCandidates.findIndex(device => device.serial === root.usbSerial);
                            return index >= 0 ? index : 0;
                        }
                        onActivated: {
                            if (currentIndex >= 0 && currentIndex < root.usbCandidates.length) {
                                root.usbSerial = root.usbCandidates[currentIndex].serial;
                            }
                        }
                    }

                    PlasmaComponents3.TextField {
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                        enabled: !root.operationBusy
                        text: root.legacyPort
                        placeholderText: i18n("Port")
                        inputMethodHints: Qt.ImhDigitsOnly
                        onTextChanged: {
                            const digits = text.replace(/[^0-9]/g, "");
                            if (digits !== text) text = digits;
                            root.legacyPort = digits;
                        }
                        PlasmaComponents3.ToolTip { text: i18n("Advanced; the default is 5555") }
                    }
                }

                PlasmaComponents3.Button {
                    Layout.alignment: Qt.AlignRight
                    text: i18n("Set up Wi-Fi")
                    icon.name: "network-wireless"
                    enabled: !root.operationBusy && root.usbSerial.length > 0
                    onClicked: root.legacySetupRequested(root.usbSerial, root.legacyPort)
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: i18n("Use the connection address from Wireless debugging, or an existing legacy ADB TCP/IP endpoint.")
                }

                RowLayout {
                    Layout.fillWidth: true

                    PlasmaComponents3.TextField {
                        Layout.fillWidth: true
                        enabled: !root.operationBusy
                        text: root.manualEndpoint
                        placeholderText: i18n("Host or IP:port")
                        onTextChanged: root.manualEndpoint = text.trim()
                    }

                    PlasmaComponents3.Button {
                        text: i18n("Connect")
                        icon.name: "network-connect"
                        enabled: !root.operationBusy
                        onClicked: root.manualConnectRequested(root.manualEndpoint)
                    }
                }
            }
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: true
            type: Kirigami.MessageType.Warning
            text: i18n("Use legacy ADB over TCP/IP only on a trusted network. Guest Wi-Fi, access-point isolation, firewalls and VPNs may prevent the connection.")
        }

        PlasmaComponents3.Frame {
            Layout.fillWidth: true
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing

                PlasmaComponents3.Label {
                    text: i18n("Connected wireless devices")
                    font.weight: Font.Medium
                }

                PlasmaComponents3.Label {
                    visible: root.wifiCandidates.length === 0
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    opacity: 0.7
                    text: i18n("No wireless ADB device is currently online.")
                }

                PlasmaComponents3.ComboBox {
                    Layout.fillWidth: true
                    visible: root.wifiCandidates.length > 0
                    enabled: !root.operationBusy
                    model: root.wifiCandidates.map(device => (device.model ? device.model + " " : "") + "(" + device.serial + ")")
                    currentIndex: {
                        const index = root.wifiCandidates.findIndex(device => device.serial === root.disconnectSerial);
                        return index >= 0 ? index : 0;
                    }
                    onActivated: {
                        if (currentIndex >= 0 && currentIndex < root.wifiCandidates.length) {
                            root.disconnectSerial = root.wifiCandidates[currentIndex].serial;
                        }
                    }
                }

                RowLayout {
                    Layout.alignment: Qt.AlignRight
                    visible: root.wifiCandidates.length > 0

                    PlasmaComponents3.Button {
                        text: i18n("Return to USB mode")
                        enabled: !root.operationBusy
                        onClicked: root.usbModeRequested(root.disconnectSerial)
                        PlasmaComponents3.ToolTip { text: i18n("Restarts ADB in USB mode; keep the cable connected") }
                    }

                    PlasmaComponents3.Button {
                        text: i18n("Disconnect")
                        icon.name: "network-disconnect"
                        enabled: !root.operationBusy
                        onClicked: root.disconnectRequested(root.disconnectSerial)
                    }
                }
            }
        }

        PlasmaComponents3.Button {
            visible: root.detailsText.length > 0
            flat: true
            text: root.detailsVisible ? i18n("Hide technical details") : i18n("Show technical details")
            onClicked: root.detailsVisible = !root.detailsVisible
        }

        PlasmaComponents3.Frame {
            Layout.fillWidth: true
            Layout.preferredHeight: Kirigami.Units.gridUnit * 8
            visible: root.detailsVisible && root.detailsText.length > 0

            QQC2.TextArea {
                anchors.fill: parent
                text: root.detailsText
                readOnly: true
                wrapMode: Text.WrapAnywhere
                font.family: "monospace"
                selectByMouse: true
            }
        }
    }
}
