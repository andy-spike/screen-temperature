import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "TemperatureSteps.js" as Steps

Panel {
  id: root
  moduleName: "io.github.andy-spike.screen-temperature"
  ipcTarget: moduleName
  manageIpc: false

  // Set by you, and by adoptReading() when hyprsunset changes the screen itself.
  property bool active: false
  property int warmTemperature: 4000
  property bool loaded: false
  property int pendingTemperature: -1
  property bool applyFailed: false
  // Last reading that disagreed with our state; the guard adopts on two in a row.
  property int lastProbe: -1

  readonly property var temperatureSteps: Steps.steps
  readonly property int neutralTemperature: Steps.neutral()
  readonly property int temperature: active ? warmTemperature : neutralTemperature
  readonly property string temperatureName: Steps.nameFor(temperature)

  // True only while adoptReading() is assigning, so following the daemon does
  // not write straight back to it. QML emits property change signals
  // synchronously, so the flag is still set when the handler below runs.
  property bool adopting: false

  // One apply per state change, no ramp: a ramp fired ~25 hyprctl calls per toggle
  // and spawned duplicate hyprsunsets fighting over the socket.
  onTemperatureChanged: if (loaded && !adopting) applyTemperature(temperature)

  // Our own file, written straight from QML. Writing the widget's shell.json
  // entry instead would make the shell reload its config on every step, which
  // rebuilds the bar widget and drops the pointer grab mid-scroll: the wheel
  // then goes dead until the mouse moves.
  readonly property string statePath: Quickshell.env("HOME") + "/.config/omarchy/screen-temperature.json"

  function persist() {
    stateFile.setText(JSON.stringify({ active: active, temperature: warmTemperature }, null, 2) + "\n")
  }

  function load(text) {
    if (loaded) return
    var state = {}
    try {
      state = JSON.parse(text) || {}
    } catch (e) {
      state = {}
    }
    warmTemperature = Steps.snap(Number(state.temperature) || 4000)
    // A stored neutral value would leave the toggle a silent no-op; heal it warm.
    if (warmTemperature >= neutralTemperature) warmTemperature = 4000
    active = state.active === true
    loaded = true
    // No apply here: hyprsunset has already put its own profile on the screen by
    // the time the shell starts, and the first probe adopts whatever that is. A
    // daemon that is not running at all is caught by the guard instead.
  }

  function setActive(value) {
    active = value && warmTemperature < neutralTemperature
  }

  function setTemperature(value) {
    var snapped = Steps.snap(value)
    // Neutral (6500) means off; keep the stored warm value for the next toggle.
    if (snapped >= neutralTemperature) {
      setActive(false)
      return
    }
    warmTemperature = snapped
    setActive(true)
  }

  function saveTemperature(value) {
    setTemperature(value)
    persist()
  }

  function saveActive(value) {
    setActive(value)
    persist()
  }

  function nudgeTemperature(direction) {
    saveTemperature(Steps.stepFrom(temperature, direction))
  }

  // Sole writer of the temperature: omarchy.nightlight is disabled, so nothing
  // else applies a value behind it. The value arrives as $1, so the script is a constant.
  readonly property string applyScript:
    "t=$1; " +
    // Bounded: a daemon stopped mid-syscall accepts the connection and never
    // replies, hanging hyprctl instead of failing it.
    "h() { timeout 1 hyprctl hyprsunset $1 $2 2>/dev/null; }; " +
    // pgrep cannot tell a healthy daemon from a dead socket, so the command is
    // the test. Read back too: a fresh hyprsunset applies its boot default over
    // anything set before it started.
    "ok() { h temperature $t >/dev/null && [ x$(h temperature | grep -oE '[0-9]+' | head -n1) = x$t ]; }; " +
    "ok && exit 0; " +
    // Replace, not add: two daemons contend for one socket. SIGKILL because a
    // stopped process leaves SIGTERM pending forever.
    "pkill -KILL -x hyprsunset; " +
    "setsid uwsm-app -- hyprsunset >/dev/null 2>&1 & " +
    // Bounded by wall clock, so a machine where hyprsunset never starts fails in seconds.
    "end=$((SECONDS+8)); " +
    "while [ $SECONDS -lt $end ]; do sleep 0.3; ok && exit 0; done; " +
    "exit 1"

  // One hyprctl at a time; a value arriving mid-apply replaces the pending one.
  function applyTemperature(value) {
    if (applyProcess.running) {
      pendingTemperature = value
      return
    }
    pendingTemperature = -1
    applyProcess.command = ["bash", "-lc", applyScript, "screen-temperature", String(value)]
    applyProcess.running = true
  }

  // Take the daemon's reading as our own state. hyprsunset owns the schedule, so
  // a temperature we did not set is a profile firing, not an intruder.
  //
  // Adopted values are not snapped: a profile may sit between our steps, and
  // writing a snapped value back would overwrite what the config asked for. The
  // slider shows the nearest step, the readout shows the truth.
  function adoptReading(value) {
    adopting = true
    if (value >= neutralTemperature) active = false
    else {
      warmTemperature = value
      active = true
    }
    adopting = false
  }

  function probe() {
    if (applyProcess.running || probeProcess.running) return
    probeProcess.running = true
  }

  // Follow hyprsunset rather than fight it. Skipped while our own apply is in
  // flight, so we never adopt a value we are in the middle of replacing.
  function guardTemperature(reading) {
    if (!loaded || applyProcess.running) return
    // A real reply is a bare number. hyprctl prints its "Couldn't connect"
    // error on stdout, not stderr, and the socket path inside it is full of
    // digits, so searching for any number reads one of those as a temperature
    // and adopts a dead daemon as "off" instead of restarting it.
    var text = String(reading).trim()
    if (!/^[0-9]+$/.test(text)) {
      lastProbe = -1
      applyTemperature(temperature)
      return
    }
    var current = Number(text)
    if (current === temperature) {
      lastProbe = -1
      return
    }
    // Two probes agreeing rules out catching the daemon mid-change.
    if (current === lastProbe) {
      lastProbe = -1
      adoptReading(current)
    } else {
      lastProbe = current
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Changing a running Timer's interval restarts its countdown, so opening the
  // panel would otherwise wait 2s for its first reading.
  onOpenedChanged: if (opened) probe()

  IpcHandler {
    target: root.moduleName

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() {
      root.saveActive(!root.active)
      return root.active ? "enabled" : "disabled"
    }
    function status() {
      return JSON.stringify({ enabled: root.active, temperature: root.temperature })
    }
  }

  // omarchy.nightlight is disabled, so its IPC target moves here and
  // omarchy-toggle-nightlight keeps resolving.
  IpcHandler {
    target: "nightlight"

    function status() {
      return JSON.stringify({ enabled: root.active, temperature: root.temperature })
    }
    // omarchy-toggle-nightlight writes the daemon directly, then calls this.
    // We own the temperature, so put our own value back rather than adopt it.
    function refresh() { root.applyTemperature(root.temperature) }
    function enable() {
      root.saveActive(true)
      return root.active ? "enabled" : "disabled"
    }
    function disable() {
      root.saveActive(false)
      return "disabled"
    }
    function toggle() {
      root.saveActive(!root.active)
      return root.active ? "enabled" : "disabled"
    }
  }

  // The state file sits at a predictable path, so it is untrusted input: any
  // process running as this user can put something else there first. FileView
  // reads the whole file the moment it has a path, and a 600 MB file lands in
  // the shell as a 1.2 GB string before JSON.parse ever runs. Our two keys never
  // reach a hundred bytes, so anything past the cap is not our state: empty it,
  // and let the load below fall back to defaults. timeout bounds the check, and
  // FileView itself refuses a FIFO, so a swapped-in pipe cannot stall the shell.
  Process {
    id: stateGuard
    running: true
    command: ["timeout", "1", "sh", "-c",
      "s=$(stat -Lc%s \"$0\" 2>/dev/null) || exit 0; [ \"$s\" -le 4096 ] || : > \"$0\"",
      root.statePath]
    // Only now, and whatever the check did: an unreadable path fails the load.
    onExited: stateFile.path = root.statePath
  }

  FileView {
    id: stateFile
    // path is set by stateGuard, never here. See the comment above.
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.load(text())
    onLoadFailed: root.load("")
  }

  Process {
    id: applyProcess
    onExited: function(code) {
      root.applyFailed = code !== 0
      if (root.pendingTemperature >= 0) root.applyTemperature(root.pendingTemperature)
    }
  }

  // Schedule follower; guardTemperature decides whether to adopt the reading.
  Process {
    id: probeProcess
    command: ["timeout", "1", "hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.guardTemperature(text)
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  // Probing keeps the display honest, and the panel is the display. A closed
  // panel only needs a cycle slow enough to notice a profile change and to find
  // a dead daemon; an open one has to feel live. Each probe spawns hyprctl, so
  // the slow cycle is ~30x fewer spawns a day than a flat 2s one.
  Timer {
    interval: root.opened ? 2000 : 30000
    repeat: true
    running: root.loaded
    onTriggered: root.probe()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖔"
    active: root.active
    tooltipText: root.temperature + "K screen temperature"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.saveActive(!root.active)
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      root.nudgeTemperature(delta > 0 ? 1 : -1)
    }
  }

  PopupCard {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    Column {
      id: content
      width: parent.width
      spacing: Style.space(14)

      Item {
        width: parent.width
        implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, currentTemperature.implicitHeight, powerSwitch.implicitHeight)

        Text {
          id: heroIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "󰖔"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.display
          opacity: root.active ? 1 : 0.5
        }

        Column {
          id: heroLabels
          anchors.left: heroIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            text: "Screen temperature"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            text: root.temperatureName
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }
        }

        Item {
          anchors.left: heroLabels.right
          anchors.right: powerSwitch.left
          anchors.rightMargin: Style.space(10)
          anchors.top: parent.top
          anchors.bottom: parent.bottom

          BorderSurface {
            id: currentTemperature
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: currentTemperatureText.implicitWidth + Style.space(10)
            implicitHeight: currentTemperatureText.implicitHeight + Style.space(4)
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)
            radius: Style.cornerRadius

            Text {
              id: currentTemperatureText
              anchors.centerIn: parent
              text: root.temperature + "K"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }
        }

        ToggleSwitch {
          id: powerSwitch
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          checked: root.active
          foreground: root.bar.foreground
          onToggled: root.saveActive(!root.active)
        }
      }

      PanelSeparator { foreground: root.bar.foreground }

      Column {
        width: parent.width
        spacing: Style.space(6)

        PanelSectionHeader {
          text: "TEMPERATURE"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        PanelSlider {
          width: parent.width
          bar: root.bar
          minimum: 0
          maximum: root.temperatureSteps.length - 1
          step: 1
          integer: true
          tickCount: root.temperatureSteps.length
          value: Steps.indexFor(root.temperature)
          onMoved: function(index) { root.setTemperature(Steps.at(index)) }
          onReleased: function(index) { root.saveTemperature(Steps.at(index)) }
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(warmerLabel.implicitHeight, neutralLabel.implicitHeight)
          Text {
            id: warmerLabel
            anchors.left: parent.left
            text: "2000K · warmer"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            id: neutralLabel
            anchors.right: parent.right
            text: "6500K · neutral"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        visible: root.applyFailed
        width: parent.width
        wrapMode: Text.Wrap
        text: "Could not reach hyprsunset."
        color: root.bar.urgent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
