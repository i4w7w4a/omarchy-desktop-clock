import QtQuick
import Quickshell.Io

QtObject {
  id: root

  required property string language
  readonly property var english: catalog(englishFile.text())
  readonly property var russian: catalog(russianFile.text())

  function catalog(data) {
    try {
      return JSON.parse(data)
    } catch (_) {
      return {}
    }
  }

  function t(key) {
    const preferred = language === "ru" ? russian : english
    return preferred[key] || english[key] || ""
  }

  property FileView englishFile: FileView {
    path: Qt.resolvedUrl("i18n/en.json").toString().slice(7)
    blockLoading: true
  }

  property FileView russianFile: FileView {
    path: Qt.resolvedUrl("i18n/ru.json").toString().slice(7)
    blockLoading: true
  }
}
