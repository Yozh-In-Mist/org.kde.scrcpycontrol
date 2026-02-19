import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.components 3.0 as PlasmaComponents3

Kirigami.FormLayout {
    PlasmaComponents3.Label {
        text: i18n("scrcpy Control stores instance names and per-device options in widget configuration.")
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
    }
}
