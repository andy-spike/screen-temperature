import QtQuick
import qs.Ui

// HH:MM entry with reliable select-all. Clicking anywhere in the box selects
// the whole value, including re-clicks on an already-focused field. Typing
// replaces the selection; a later click moves the cursor instead of re-selecting.
TextField {
  id: root

  // True while the user has typed since the last select-all.
  property bool typed: false

  inputMethodHints: Qt.ImhTime
  selectByMouse: true

  onTextEdited: typed = true

  onActiveFocusChanged: {
    if (activeFocus) typed = false
    if (activeFocus) Qt.callLater(selectAll)
  }

  // A click collapses the selection to the cursor; re-select unless the
  // collapse came from typing.
  onSelectionStartChanged: if (activeFocus && selectionStart === selectionEnd && !typed) Qt.callLater(selectAll)
  onSelectionEndChanged: if (activeFocus && selectionStart === selectionEnd && !typed) Qt.callLater(selectAll)
}