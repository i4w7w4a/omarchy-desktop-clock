pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell.Wayland
import qs.Commons as Commons
import qs.Ui as Ui

Item {
  id: root

  property var shell: null
  property var service: null
  property bool opened: false
  property string draftFamily: ""
  property bool applyRejected: false

  readonly property string pluginId: "io.github.i4w7w4a.desktop-clock"
  readonly property var activeService: service || (shell ? shell.serviceFor(pluginId) : null)
  readonly property Settings settings: activeService ? activeService.settings : null
  readonly property color foreground: Commons.Color.popups.text
  readonly property string savedFamily: settings ? settings.saved.fontFamily : "Inter"
  readonly property string fontFamily: draftFamily || savedFamily
  readonly property bool canWrite: !!settings && settings.canWrite
  readonly property bool saving: !!settings && settings.saving
  readonly property bool dirty: fontFamily !== savedFamily
  readonly property var installedFonts: Qt.fontFamilies()
    .filter(name => name !== "Inter" && name !== "Inter Variable")
    .sort((a, b) => a.localeCompare(b))

  function open(payload) {
    opened = true
  }

  function close() {
    fontPicker.close()
    opened = false
    draftFamily = ""
    applyRejected = false
  }

  function dismiss() {
    if (!shell || !shell.hide(pluginId)) close()
  }

  onSavedFamilyChanged: {
    if (draftFamily === savedFamily) draftFamily = ""
  }

  ClockSettingsStrings {
    id: labels
    language: root.settings ? root.settings.language : (Commons.I18n.language === "ru" ? "ru" : "en")
  }

  Ui.OverlayWindow {
    id: overlay
    shown: root.opened
    WlrLayershell.namespace: "i4w7w4a-minute-ink-settings"

    Binding { target: overlay.contentItem; property: "LayoutMirroring.enabled"; value: false }

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim

      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    Ui.BorderSurface {
      id: card

      anchors.centerIn: parent
      width: Math.max(1, Math.min(Commons.Style.space(420), parent.width - Commons.Style.space(32)))
      height: form.implicitHeight + contentTopInset + contentBottomInset
      radius: Commons.Style.cornerRadius
      padding: Commons.Style.spacing.popupPadding
      color: Commons.Color.popups.background
      borderSpec: Commons.Border.surfaceSpec("popups", "border", Commons.Color.popups.border,
        Math.max(1, Commons.Style.space(2)))

      MouseArea { anchors.fill: parent }

      FocusScope {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        focus: true
        Keys.onEscapePressed: {
          if (fontPicker.popupOpen) fontPicker.close()
          else root.dismiss()
        }

        ColumnLayout {
          id: form
          anchors.fill: parent
          spacing: Commons.Style.spacing.lg

          RowLayout {
            Layout.fillWidth: true
            spacing: Commons.Style.spacing.sm

            Text {
              Layout.fillWidth: true
              text: labels.t("panel.title")
              textFormat: Text.PlainText
              color: root.foreground
              font.family: Commons.Style.font.family
              font.pixelSize: Commons.Style.font.heading
              font.bold: true
              wrapMode: Text.Wrap
            }

            Ui.ButtonGroup {
              objectName: "clockSettingsLanguage"
              foreground: root.foreground
              background: Commons.Color.popups.background
              value: labels.language
              options: [
                { value: "ru", label: labels.t("language.ru") },
                { value: "en", label: labels.t("language.en") }
              ]
              enabled: root.canWrite
              Accessible.name: labels.t("language.title")
              onChanged: function(code) { root.settings.setLanguage(code) }
            }
          }

          Ui.SearchableDropdown {
            id: fontPicker
            objectName: "clockSetting_fontFamily"
            Layout.fillWidth: true
            label: labels.t("setting.fontFamily")
            placeholderText: labels.t("action.search")
            emptyText: labels.t("status.noMatches")
            options: [{ value: "Inter", label: labels.t("font.inter") }].concat(root.installedFonts)
            enabled: root.canWrite && !root.saving
            opacity: enabled ? 1 : 0.5
            value: root.fontFamily
            Accessible.role: Accessible.ComboBox
            Accessible.name: label
            Accessible.description: currentLabel()
            Accessible.onPressAction: if (enabled) toggle()

            // The Shell control assigns value itself on selection.
            Connections {
              target: root
              function onFontFamilyChanged() { fontPicker.value = root.fontFamily }
            }

            onChanged: function(family) {
              root.draftFamily = family === root.savedFamily ? "" : family
              root.applyRejected = false
            }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Commons.Style.spacing.sm

            Text {
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              color: root.foreground
              font.family: Commons.Style.font.family
              font.pixelSize: Commons.Style.font.bodySmall
              text: {
                if (!root.canWrite) return labels.t("status.unavailable")
                if (root.saving) return labels.t("status.saving")
                if (root.applyRejected || root.settings.saveFailed) return labels.t("status.saveFailed")
                return ""
              }
            }

            Ui.Button {
              objectName: "clockSettingsCancel"
              foreground: root.foreground
              bordered: true
              focusable: true
              text: labels.t("action.cancel")
              Accessible.role: Accessible.Button
              Accessible.name: text
              Accessible.onPressAction: root.dismiss()
              onClicked: root.dismiss()
            }

            Ui.Button {
              objectName: "clockSettingsApply"
              foreground: root.foreground
              bordered: true
              focusable: true
              text: labels.t("action.apply")
              enabled: root.canWrite && !root.saving && root.dirty
              opacity: enabled ? 1 : 0.5
              selected: enabled
              Accessible.role: Accessible.Button
              Accessible.name: text
              Accessible.onPressAction: if (enabled) clicked()
              onClicked: root.applyRejected = !root.settings.setFontFamily(root.fontFamily)
            }
          }
        }
      }
    }
  }
}
