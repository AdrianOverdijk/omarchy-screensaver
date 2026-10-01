import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "adrian.screensaver"

  readonly property string home: Quickshell.env("HOME")
  readonly property string shellConfigPath: home + "/.config/omarchy/shell.json"
  readonly property string stayAwakePath: home + "/.local/state/omarchy/indicators/stay-awake"

  // This plugin's bin/ directory as a plain path (Qt.resolvedUrl percent-encodes it).
  readonly property string pluginBin:
    decodeURIComponent(String(Qt.resolvedUrl("bin/")).replace(/^file:\/\//, ""))

  // Same fallbacks as the idle service when shell.json has no idle block.
  readonly property int defaultScreensaver: 150
  readonly property int defaultLock: 300

  // The values in shell.json, and the ones shown in the popup. They differ
  // only while an edit is waiting for the debounce timer to write it.
  property int savedScreensaver: defaultScreensaver
  property int savedLock: defaultLock
  property int screensaver: defaultScreensaver
  property int lock: defaultLock
  readonly property bool dirty: screensaver !== savedScreensaver || lock !== savedLock

  property bool stayAwake: false
  property bool popupOpen: false

  // The word can also be changed outside the popup (bin/set-word), so read
  // it fresh each time the popup opens and drop any stale status message.
  onPopupOpenChanged: {
    if (!popupOpen) return
    wordMessage = ""
    wordError = false
    wordFile.reload()
  }

  // Values the +/- buttons step through.
  readonly property var steps: [15, 30, 45, 60, 90, 120, 150, 180, 240, 300, 420, 600,
                                900, 1200, 1800, 2700, 3600, 5400, 7200]

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color popupText: Color.popups.text
  readonly property color popupMuted: Qt.darker(popupText, 1.4)

  function close() {
    popupOpen = false
  }

  function formatDuration(seconds) {
    if (seconds >= 3600) {
      var h = Math.floor(seconds / 3600)
      var m = Math.round((seconds % 3600) / 60)
      return h + " h" + (m > 0 ? " " + m + " min" : "")
    }
    var mins = Math.floor(seconds / 60)
    var secs = seconds % 60
    if (mins === 0) return secs + " s"
    return mins + ":" + (secs < 10 ? "0" : "") + secs
  }

  readonly property string summary: {
    if (lock <= screensaver) return "Locks without showing the screensaver"
    return "Screensaver shows for " + formatDuration(lock - screensaver) + " before locking"
  }

  function stepFrom(value, direction) {
    if (direction > 0) {
      for (var i = 0; i < steps.length; i++) if (steps[i] > value) return steps[i]
      return steps[steps.length - 1]
    }
    for (var j = steps.length - 1; j >= 0; j--) if (steps[j] < value) return steps[j]
    return steps[0]
  }

  // The lock never comes before the screensaver: moving one past the other
  // drags the other along.
  function adjustScreensaver(direction) {
    screensaver = stepFrom(screensaver, direction)
    if (lock < screensaver) lock = screensaver
    writeTimer.restart()
  }

  function adjustLock(direction) {
    lock = stepFrom(lock, direction)
    if (screensaver > lock) screensaver = lock
    writeTimer.restart()
  }

  function setValues(newScreensaver, newLock) {
    screensaver = newScreensaver
    lock = newLock
    writeTimer.restart()
  }

  function positiveInt(value, fallback) {
    var n = Number(value)
    return isFinite(n) && n > 0 ? Math.round(n) : fallback
  }

  function readConfig(text) {
    var idle = {}
    try {
      var parsed = JSON.parse(text)
      if (parsed && parsed.idle) idle = parsed.idle
    } catch (e) {
      return
    }
    savedScreensaver = positiveInt(idle.screensaver, defaultScreensaver)
    savedLock = positiveInt(idle.lock, defaultLock)
    // Don't clobber an edit that hasn't been written yet.
    if (!writeTimer.running && !writeProc.running) {
      screensaver = savedScreensaver
      lock = savedLock
    }
  }

  FileView {
    id: configFile
    path: root.shellConfigPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readConfig(text())
  }

  // The stay-awake flag is a marker file; FileView can't watch a file that
  // doesn't exist yet, so poll it instead.
  FileView {
    id: stayAwakeFile
    path: root.stayAwakePath
    watchChanges: false
    printErrors: false
    onLoaded: root.stayAwake = true
    onLoadFailed: root.stayAwake = false
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: stayAwakeFile.reload()
  }

  // Batch quick +/- clicks into one write.
  Timer {
    id: writeTimer
    interval: 600
    onTriggered: root.writeValues()
  }

  function writeValues() {
    if (!dirty) return
    if (writeProc.running) {
      writeTimer.restart()
      return
    }
    writeProc.command = ["/usr/bin/python3", pluginBin + "set-idle",
                         String(screensaver), String(lock)]
    writeProc.running = true
  }

  Process {
    id: writeProc
    stderr: StdioCollector {
      onStreamFinished: if (text.trim() !== "") console.warn("adrian.screensaver: " + text.trim())
    }
    onExited: configFile.reload()
  }

  function toggleStayAwake() {
    Quickshell.execDetached(["omarchy-toggle-idle", "toggle"])
    stayAwakeRefresh.restart()
  }

  Timer {
    id: stayAwakeRefresh
    interval: 300
    onTriggered: stayAwakeFile.reload()
  }

  function previewScreensaver() {
    close()
    Quickshell.execDetached(["omarchy-launch-screensaver", "force"])
  }

  // ---------------------------------------------------------------- word
  // The custom word shown by the screensaver, drawn in the logo's lettering.
  // set-word renders it into ~/.config/omarchy/branding/screensaver.txt and
  // remembers it here; no file means the stock logo is showing.
  readonly property string wordStatePath: home + "/.local/state/omarchy/adrian.screensaver/word"
  property string word: ""
  property string wordMessage: ""
  property bool wordError: false

  FileView {
    id: wordFile
    path: root.wordStatePath
    watchChanges: false
    printErrors: false
    onLoaded: root.word = text().trim()
    onLoadFailed: root.word = ""
  }

  function applyWord(text) {
    var value = String(text || "").trim()
    if (value === "" || wordProc.running) return
    wordProc.command = ["/bin/bash", pluginBin + "set-word", value]
    wordProc.running = true
  }

  function resetWord() {
    if (wordProc.running) return
    wordProc.command = ["/bin/bash", pluginBin + "set-word", "--reset"]
    wordProc.running = true
  }

  Process {
    id: wordProc
    stderr: StdioCollector {
      id: wordErr
    }
    onExited: function(exitCode) {
      root.wordError = exitCode !== 0
      root.wordMessage = exitCode === 0 ? "Saved — click Preview to see it"
                                        : (wordErr.text.trim().replace(/^render-word: /, "") || "Couldn't save the word")
      wordFile.reload()
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.stayAwake ? "󰅶" : "󰒲"   // nf-md-coffee / nf-md-sleep
    active: root.popupOpen
    fontSize: Style.font.body
    tooltipText: root.stayAwake
      ? "Stay awake is on — screensaver and lock are paused"
      : "Screensaver after " + root.formatDuration(root.savedScreensaver)
        + "  •  lock after " + root.formatDuration(root.savedLock)
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.toggleStayAwake()
      else root.popupOpen = !root.popupOpen
    }
  }

  component StepRow: Item {
    id: row
    property string label: ""
    property int value: 0
    signal step(int direction)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(minus.implicitHeight, valueText.implicitHeight)

    Text {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: row.label
      color: root.popupText
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Button {
      id: plus
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: "+"
      foreground: root.popupText
      bordered: true
      horizontalPadding: 9
      verticalPadding: 2
      fontSize: Style.font.body
      enabled: row.value < root.steps[root.steps.length - 1]
      onClicked: row.step(1)
    }

    Text {
      id: valueText
      anchors.right: plus.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(64)
      horizontalAlignment: Text.AlignHCenter
      text: root.formatDuration(row.value)
      color: root.popupText
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }

    Button {
      id: minus
      anchors.right: valueText.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: "−"
      foreground: root.popupText
      bordered: true
      horizontalPadding: 9
      verticalPadding: 2
      fontSize: Style.font.body
      enabled: row.value > root.steps[0]
      onClicked: row.step(-1)
    }
  }

  // KeyboardPanel rather than PopupCard: an xdg-popup never gets keyboard
  // focus, so the text field below couldn't be typed into.
  KeyboardPanel {
    id: popup
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.popupOpen
    focusTarget: wordField
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      PanelHero {
        width: parent.width
        title: "Screensaver"
        meta: root.stayAwake
          ? "Paused · stay awake is on"
          : "After " + root.formatDuration(root.savedScreensaver) + " idle · lock at " + root.formatDuration(root.savedLock)
        foreground: root.popupText
        fontFamily: root.fontFamily
        iconOpacity: root.stayAwake ? 0.5 : 1.0
        iconComponent: Component {
          Text {
            text: root.stayAwake ? "󰅶" : "󰒲"   // nf-md-coffee / nf-md-sleep
            color: root.popupText
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
        }
      }

      PanelSeparator {
        width: parent.width
        foreground: root.popupText
      }

      StepRow {
        label: "Screensaver after"
        value: root.screensaver
        onStep: function(direction) { root.adjustScreensaver(direction) }
      }

      StepRow {
        label: "Lock after"
        value: root.lock
        onStep: function(direction) { root.adjustLock(direction) }
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: root.summary + (root.dirty ? "  (saving…)" : "")
        color: root.popupMuted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Button {
        text: root.stayAwake ? "Allow idle" : "Stay awake"
        iconText: "󰅶"
        foreground: root.popupText
        bordered: true
        selected: root.stayAwake
        horizontalPadding: 8
        verticalPadding: 3
        fontSize: Style.font.bodySmall
        iconSize: Style.font.bodySmall
        onClicked: root.toggleStayAwake()
      }

      PanelSeparator {
        width: parent.width
        foreground: root.popupText
      }

      Text {
        text: "SCREENSAVER TEXT"
        color: root.popupMuted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
      }

      Item {
        width: parent.width
        implicitHeight: wordField.implicitHeight

        TextField {
          id: wordField
          anchors.left: parent.left
          anchors.right: applyButton.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          foreground: root.popupText
          font.family: root.fontFamily
          placeholderText: root.word !== "" ? root.word : "OMARCHY"
          maximumLength: 40
          onAccepted: root.applyWord(text)
          onTextChanged: root.wordMessage = ""
          Keys.onEscapePressed: root.close()
        }

        Button {
          id: applyButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "Apply"
          foreground: root.popupText
          bordered: true
          horizontalPadding: 8
          verticalPadding: 3
          fontSize: Style.font.bodySmall
          enabled: wordField.text.trim() !== ""
          onClicked: root.applyWord(wordField.text)
        }
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: root.wordMessage !== "" ? root.wordMessage
          : (root.word !== "" ? "Showing “" + root.word.toUpperCase() + "” · letters A–Z only"
                              : "Showing the Omarchy logo · letters A–Z only")
        color: root.wordError ? Color.urgent : root.popupMuted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Flow {
        width: parent.width
        spacing: Style.space(6)

        Button {
          text: "Logo"
          iconText: "󰣇"
          foreground: root.popupText
          bordered: true
          horizontalPadding: 8
          verticalPadding: 3
          fontSize: Style.font.bodySmall
          iconSize: Style.font.bodySmall
          enabled: root.word !== ""
          tooltipText: "Put the Omarchy logo back on the screensaver"
          onClicked: root.resetWord()
        }

        Button {
          text: "Preview"
          iconText: "󰐊"
          foreground: root.popupText
          bordered: true
          horizontalPadding: 8
          verticalPadding: 3
          fontSize: Style.font.bodySmall
          iconSize: Style.font.bodySmall
          onClicked: root.previewScreensaver()
        }

        Button {
          text: "Defaults"
          iconText: "󰑓"
          foreground: root.popupText
          bordered: true
          horizontalPadding: 8
          verticalPadding: 3
          fontSize: Style.font.bodySmall
          iconSize: Style.font.bodySmall
          enabled: root.screensaver !== root.defaultScreensaver || root.lock !== root.defaultLock
          onClicked: root.setValues(root.defaultScreensaver, root.defaultLock)
        }
      }
    }
  }
}
