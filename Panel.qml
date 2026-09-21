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
  property string pendingState: ""
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
  readonly property string stateHelper: decodeURIComponent(String(Qt.resolvedUrl("state_file.py")).replace(/^file:\/\//, ""))

  // Start children with only the session values needed for state and IPC.
  // With clearEnvironment, null copies that one value from the shell.
  // In particular, never inherit PATH, loader options, or interpreter hooks.
  readonly property var processEnvironment: ({
    PATH: "/usr/bin:/bin",
    HOME: null,
    XDG_CONFIG_HOME: null,
    XDG_RUNTIME_DIR: null,
    WAYLAND_DISPLAY: null,
    HYPRLAND_INSTANCE_SIGNATURE: null,
    DBUS_SESSION_BUS_ADDRESS: null
  })

  function persist() {
    pendingState = JSON.stringify({ active: active, temperature: warmTemperature }, null, 2) + "\n"
    if (!stateWriter.running) writeState()
  }

  function writeState() {
    var contents = pendingState
    pendingState = ""
    stateWriter.command = ["/usr/bin/python3", "-I", "-S", stateHelper, "write", statePath, contents]
    stateWriter.running = true
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
    // The daemon can start at 6000K before its first profile fires. Apply the
    // saved state now so a disabled plugin starts at neutral (6500K).
    applyTemperature(temperature)
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
    // Fail before stopping a daemon if its recovery tools are unavailable.
    "for tool in timeout hyprctl grep head pkill setsid uwsm-app env hyprsunset sleep; do " +
    "[ -x /usr/bin/$tool ] || exit 1; done; " +
    // Bounded: a daemon stopped mid-syscall accepts the connection and never
    // replies, hanging hyprctl instead of failing it.
    "h() { /usr/bin/timeout 1 /usr/bin/hyprctl hyprsunset $1 $2 2>/dev/null; }; " +
    // pgrep cannot tell a healthy daemon from a dead socket, so the command is
    // the test. Read back too: a fresh hyprsunset applies its boot default over
    // anything set before it started.
    "ok() { h temperature $t >/dev/null && [ x$(h temperature | /usr/bin/grep -oE '[0-9]+' | /usr/bin/head -n1) = x$t ]; }; " +
    "ok && exit 0; " +
    // Replace, not add: two daemons contend for one socket. SIGKILL because a
    // stopped process leaves SIGTERM pending forever.
    "/usr/bin/pkill -KILL -x hyprsunset; " +
    // UWSM launches through its daemon, which has a separate environment.
    // Rebuild the environment there too, before hyprsunset starts.
    "/usr/bin/setsid /usr/bin/uwsm-app -- /usr/bin/env -i PATH=/usr/bin:/bin " +
    "HOME=\"$HOME\" XDG_CONFIG_HOME=\"${XDG_CONFIG_HOME:-$HOME/.config}\" " +
    "XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\" WAYLAND_DISPLAY=\"$WAYLAND_DISPLAY\" " +
    "HYPRLAND_INSTANCE_SIGNATURE=\"$HYPRLAND_INSTANCE_SIGNATURE\" " +
    "DBUS_SESSION_BUS_ADDRESS=\"$DBUS_SESSION_BUS_ADDRESS\" " +
    "/usr/bin/hyprsunset >/dev/null 2>&1 & " +
    // Bounded by wall clock, so a machine where hyprsunset never starts fails in seconds.
    "end=$((SECONDS+8)); " +
    "while [ $SECONDS -lt $end ]; do /usr/bin/sleep 0.3; ok && exit 0; done; " +
    "exit 1"

  // One hyprctl at a time; a value arriving mid-apply replaces the pending one.
  function applyTemperature(value) {
    if (applyProcess.running) {
      pendingTemperature = value
      return
    }
    pendingTemperature = -1
    applyProcess.command = ["/usr/bin/bash", "--noprofile", "--norc", "-c", applyScript, "screen-temperature", String(value)]
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

  function adoptNightlightRefresh(reading) {
    var text = String(reading).trim()
    if (!/^[0-9]+$/.test(text)) return
    adoptReading(Number(text))
    persist()
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
    // omarchy-toggle-nightlight writes and verifies the daemon before calling
    // this, so one reading is enough to adopt and persist its result.
    function refresh() {
      if (!nightlightRefresh.running) nightlightRefresh.running = true
    }
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

  // Open, validate, and read through one descriptor. The helper rejects links,
  // non-regular files, and anything over 4 KB without resolving the path twice.
  Process {
    id: stateReader
    clearEnvironment: true
    environment: root.processEnvironment
    running: true
    command: ["/usr/bin/timeout", "1", "/usr/bin/python3", "-I", "-S", root.stateHelper, "read", root.statePath]
    stdout: StdioCollector { id: stateOutput; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) { root.load(code === 0 ? stateOutput.text : "") }
  }

  Process {
    id: stateWriter
    clearEnvironment: true
    environment: root.processEnvironment
    stderr: StdioCollector { waitForEnd: true }
    onExited: if (root.pendingState !== "") root.writeState()
  }

  Process {
    id: applyProcess
    clearEnvironment: true
    environment: root.processEnvironment
    onExited: function(code) {
      root.applyFailed = code !== 0
      if (root.pendingTemperature >= 0) root.applyTemperature(root.pendingTemperature)
    }
  }

  // Schedule follower; guardTemperature decides whether to adopt the reading.
  Process {
    id: probeProcess
    clearEnvironment: true
    environment: root.processEnvironment
    command: ["/usr/bin/timeout", "1", "/usr/bin/hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.guardTemperature(text)
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: nightlightRefresh
    clearEnvironment: true
    environment: root.processEnvironment
    command: ["/usr/bin/timeout", "1", "/usr/bin/hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector { id: nightlightRefreshOutput; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      if (code === 0) root.adoptNightlightRefresh(nightlightRefreshOutput.text)
    }
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
