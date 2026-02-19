// SPDX-License-Identifier: GPL-3.0-or-later
import QtQuick 2.15
import QtQuick.Layouts 1.15

import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.components 3.0 as PlasmaComponents3

import "logic.js" as Logic

PlasmaComponents3.Frame {
    id: root

    Layout.fillWidth: true
    padding: Kirigami.Units.smallSpacing

    required property var plasmoidObj

    property string deviceSerial: ""
    property var defaults: ({})

    signal createRequested(string deviceSerial, string name, var args)
    signal saveDefaultsRequested(string deviceSerial, var flagsObj)

    property bool videoEnabled: true
    property bool audioEnabled: true
    property bool controlEnabled: true
    property bool windowEnabled: true

    property string additionalFlags: ""
    property string instanceName: ""

    property var templates: []
    property string selectedTemplateName: ""
    property string flagsValidationError: ""

    // Convert validation codes into translatable, user-facing diagnostics.
    function validationErrorText(result) {
        if (!result || !result.errorCode) return "";
        if (result.errorCode === "trailing_escape") return i18n("Trailing escape in flags input.");
        if (result.errorCode === "unterminated_quote") return i18n("Unterminated quote in flags input.");
        if (result.errorCode === "forbidden_flag") {
            return i18n("Flag \"%1\" is not allowed here. Device selection is controlled by the widget UI.", result.forbiddenFlag || "");
        }
        return i18n("The provided flags are invalid.");
    }

    function reloadTemplates() {
        templates = Logic.getTemplates(root.plasmoidObj);
        if (!selectedTemplateName.length) return;

        const exists = templates.some(template => template && String(template.name) === selectedTemplateName);
        if (!exists) selectedTemplateName = "";
    }

    function loadDefaults() {
        instanceName = "";
        videoEnabled = defaults.videoEnabled !== undefined ? !!defaults.videoEnabled : true;
        audioEnabled = defaults.audioEnabled !== undefined ? !!defaults.audioEnabled : true;
        controlEnabled = defaults.controlEnabled !== undefined ? !!defaults.controlEnabled : true;
        windowEnabled = defaults.windowEnabled !== undefined ? !!defaults.windowEnabled : true;
        additionalFlags = Logic.sanitizeFlagsInput(defaults.additionalFlags ? String(defaults.additionalFlags) : "");
        reloadTemplates();
    }

    Component.onCompleted: loadDefaults()
    onDefaultsChanged: loadDefaults()

    function buildArgs() {
        // Build baseline argument set from checkbox state.
        const args = [];
        if (!videoEnabled) args.push("--no-video");
        if (!audioEnabled) args.push("--no-audio");
        if (!controlEnabled) args.push("--no-control");
        if (!windowEnabled) args.push("--no-window");
        return args;
    }

    function validateAdditionalFlagsOrShowError() {
        const result = Logic.validateAdditionalFlagsInput(additionalFlags);
        additionalFlags = result.sanitized;
        flagsValidationError = validationErrorText(result);

        if (!result.ok) {
            flagsErrorDialog.open();
            return null;
        }

        return result.args;
    }

    function buildArgsOrShowError() {
        const extraArgs = validateAdditionalFlagsOrShowError();
        if (extraArgs === null) return null;

        const args = buildArgs();
        for (let i = 0; i < extraArgs.length; i++) args.push(extraArgs[i]);
        return args;
    }

    function buildDefaultsObj() {
        return {
            videoEnabled,
            audioEnabled,
            controlEnabled,
            windowEnabled,
            additionalFlags
        };
    }

    Kirigami.Dialog {
        id: editTemplateDialog

        title: i18n("Edit template")
        modal: true
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel

        property string oldName: ""

        ColumnLayout {
            width: Kirigami.Units.gridUnit * 34
            implicitHeight: Kirigami.Units.gridUnit * 11
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.Label {
                text: i18n("Template name")
                opacity: 0.8
            }

            PlasmaComponents3.TextField {
                id: tplNameField
                Layout.fillWidth: true
                placeholderText: i18n("Name")
            }

            PlasmaComponents3.Label {
                text: i18n("Additional Flags")
                opacity: 0.8
            }

            PlasmaComponents3.TextField {
                id: tplFlagsField
                Layout.fillWidth: true
                placeholderText: i18n("Additional Flags")
                onTextChanged: {
                    const cleaned = Logic.sanitizeFlagsInput(text);
                    if (cleaned !== text) text = cleaned;
                }
            }
        }

        onAccepted: {
            const name = tplNameField.text.trim();
            if (!name.length) return;

            const validation = Logic.validateAdditionalFlagsInput(tplFlagsField.text);
            if (!validation.ok) {
                root.flagsValidationError = root.validationErrorText(validation);
                flagsErrorDialog.open();
                return;
            }

            const flags = validation.sanitized;
            const previousName = String(editTemplateDialog.oldName || "").trim();

            if (previousName.length && previousName !== name) Logic.removeTemplate(root.plasmoidObj, previousName);
            Logic.upsertTemplate(root.plasmoidObj, name, flags);

            root.selectedTemplateName = name;
            root.additionalFlags = flags;
            root.reloadTemplates();
        }
    }

    Kirigami.Dialog {
        id: flagsErrorDialog

        title: i18n("Invalid Flags")
        modal: true
        standardButtons: Kirigami.Dialog.Ok

        ColumnLayout {
            width: Kirigami.Units.gridUnit * 22
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.Label {
                wrapMode: Text.WordWrap
                text: root.flagsValidationError.length
                    ? root.flagsValidationError
                    : i18n("The provided flags are invalid.")
            }
        }
    }

    function openEditTemplateDialog(prefillName, prefillFlags) {
        editTemplateDialog.oldName = String(prefillName || "").trim();
        tplNameField.text = prefillName || "";
        tplFlagsField.text = prefillFlags || root.additionalFlags || "";
        editTemplateDialog.open();
    }

    Kirigami.Dialog {
        id: deleteTemplateDialog

        title: i18n("Delete template")
        modal: true
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel

        ColumnLayout {
            width: Kirigami.Units.gridUnit * 22
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.Label {
                wrapMode: Text.WordWrap
                text: i18n("Delete template “%1”?", root.selectedTemplateName)
            }
        }

        onAccepted: {
            const name = root.selectedTemplateName.trim();
            if (!name.length) return;

            Logic.removeTemplate(root.plasmoidObj, name);
            root.selectedTemplateName = "";
            root.reloadTemplates();
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents3.Label {
            text: i18n("Create instance")
            opacity: 0.8
        }

        PlasmaComponents3.TextField {
            Layout.fillWidth: true
            placeholderText: i18n("Instance name (optional)")
            text: root.instanceName
            onTextChanged: root.instanceName = text
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.CheckBox {
                text: i18n("Video")
                checked: root.videoEnabled
                onToggled: root.videoEnabled = checked
                PlasmaComponents3.ToolTip { text: i18n("Disable to add %1", "--no-video") }
            }

            PlasmaComponents3.CheckBox {
                text: i18n("Audio")
                checked: root.audioEnabled
                onToggled: root.audioEnabled = checked
                PlasmaComponents3.ToolTip { text: i18n("Disable to add %1", "--no-audio") }
            }

            PlasmaComponents3.CheckBox {
                text: i18n("Control")
                checked: root.controlEnabled
                onToggled: root.controlEnabled = checked
                PlasmaComponents3.ToolTip { text: i18n("Disable to add %1", "--no-control") }
            }

            PlasmaComponents3.CheckBox {
                text: i18n("Window")
                checked: root.windowEnabled
                onToggled: root.windowEnabled = checked
                PlasmaComponents3.ToolTip { text: i18n("Disable to add %1", "--no-window") }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            PlasmaComponents3.Label {
                text: i18n("Templates")
                opacity: 0.8
            }

            PlasmaComponents3.ComboBox {
                id: templateCombo

                Layout.fillWidth: true
                model: [""].concat((root.templates || []).map(template => String(template.name)))

                currentIndex: {
                    if (!root.selectedTemplateName.length) return 0;
                    const index = (root.templates || []).findIndex(template => String(template.name) === root.selectedTemplateName);
                    return index >= 0 ? index + 1 : 0;
                }

                displayText: currentIndex === 0 ? i18n("None") : model[currentIndex]

                onActivated: {
                    if (currentIndex === 0) {
                        root.selectedTemplateName = "";
                        return;
                    }

                    const name = model[currentIndex];
                    const template = (root.templates || []).find(item => String(item.name) === name);
                    if (!template) return;

                    root.selectedTemplateName = name;
                    root.additionalFlags = Logic.sanitizeFlagsInput(String(template.flags || ""));
                }

                PlasmaComponents3.ToolTip { text: i18n("Select a template to fill Additional Flags") }
            }

            PlasmaComponents3.ToolButton {
                icon.name: "document-save"
                onClicked: openEditTemplateDialog(root.selectedTemplateName, root.additionalFlags)
                PlasmaComponents3.ToolTip { text: i18n("Save current Additional Flags as a template") }
            }

            PlasmaComponents3.ToolButton {
                icon.name: "list-add"
                onClicked: openEditTemplateDialog("", "")
                PlasmaComponents3.ToolTip { text: i18n("Create a new template") }
            }

            PlasmaComponents3.ToolButton {
                enabled: root.selectedTemplateName.length > 0
                icon.name: "document-edit"
                onClicked: {
                    const template = (root.templates || []).find(item => String(item.name) === root.selectedTemplateName);
                    openEditTemplateDialog(root.selectedTemplateName, template ? String(template.flags || "") : root.additionalFlags);
                }
                PlasmaComponents3.ToolTip { text: i18n("Edit selected template") }
            }

            PlasmaComponents3.ToolButton {
                enabled: root.selectedTemplateName.length > 0
                icon.name: "edit-delete"
                onClicked: deleteTemplateDialog.open()
                PlasmaComponents3.ToolTip { text: i18n("Delete selected template") }
            }
        }

        PlasmaComponents3.Label {
            text: i18n("Additional Flags")
            opacity: 0.8
        }

        PlasmaComponents3.TextField {
            Layout.fillWidth: true
            placeholderText: i18n("Additional Flags")
            text: root.additionalFlags
            onTextChanged: {
                const cleaned = Logic.sanitizeFlagsInput(text);
                if (cleaned !== text) {
                    text = cleaned;
                    return;
                }
                root.additionalFlags = cleaned;
            }
            PlasmaComponents3.ToolTip { text: i18n("Any extra scrcpy flags (advanced)") }
        }

        RowLayout {
            Layout.fillWidth: true

            PlasmaComponents3.Button {
                text: i18n("Save as device default")
                icon.name: "document-save"
                onClicked: {
                    const extraArgs = root.validateAdditionalFlagsOrShowError();
                    if (extraArgs === null) return;
                    root.saveDefaultsRequested(root.deviceSerial, root.buildDefaultsObj());
                }
                PlasmaComponents3.ToolTip { text: i18n("Use these options as default for this device") }
            }

            Item { Layout.fillWidth: true }

            PlasmaComponents3.Button {
                text: i18n("Start")
                icon.name: "media-playback-start"
                onClicked: {
                    const args = root.buildArgsOrShowError();
                    if (args === null) return;
                    root.createRequested(root.deviceSerial, root.instanceName, args);
                }
                PlasmaComponents3.ToolTip { text: i18n("Start a new scrcpy instance for this device") }
            }
        }
    }
}
