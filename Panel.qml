import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ScheduleModel.js" as ScheduleModel

Panel {
  id: root
  moduleName: "io.github.andy-spike.screen-temperature"
  ipcTarget: moduleName
  manageIpc: false

  readonly property string helper: Qt.resolvedUrl("schedule.py").toString().replace("file://", "")
  // The toggle owns `active`: probing the daemon would let a stale reading undo it.
  property bool active: false
  property int scheduledTemperature: 3000
  property bool scheduleEnabled: true
  property string warmFrom: "19:00"
  property string normalAt: "04:00"
  property string error: ""
  property string done: ""
  property bool stateLoaded: false
  property bool scheduledPeriodActive: false
  property bool saveQueued: false
  property int pendingTemperature: -1
  // Epoch ms when a manual override hands control back to the schedule; 0 = none.
  property real overrideUntil: 0
  property bool applyFailed: false
  // Last reading that disagreed with our intent; the guard needs two in a row.
  property int lastProbe: -1

  readonly property int neutralTemperature: temperatureSteps[temperatureSteps.length - 1]
  readonly property int temperature: active ? scheduledTemperature : neutralTemperature

  // One apply per state change, no ramp: a ramp fired ~25 hyprctl calls per toggle
  // and spawned duplicate hyprsunsets fighting over the socket.
  onTemperatureChanged: if (stateLoaded) applyTemperature(temperature)
  readonly property string temperatureName: nameForTemperature(temperature)

  function nameForTemperature(value) {
    if (value >= 6000) return "NEUTRAL"
    if (value >= 4500) return "SOFT"
    if (value >= 3200) return "WARM"
    return "AMBER"
  }

  // hyprsunset dislikes a firehose of changes, so the slider stops on fixed steps.
  readonly property var temperatureSteps: [2000, 2500, 3000, 3500, 4000, 4500, 5000, 5500, 6000, 6500]

  function stepIndexFor(value) {
    var best = 0
    for (var i = 1; i < temperatureSteps.length; i++)
      if (Math.abs(temperatureSteps[i] - value) < Math.abs(temperatureSteps[best] - value)) best = i
    return best
  }

  function stepTemperature(index) {
    return temperatureSteps[Math.max(0, Math.min(temperatureSteps.length - 1, index))]
  }

  function snapTemperature(value) {
    return temperatureSteps[stepIndexFor(value)]
  }

  function setActive(value) {
    active = value && scheduledTemperature < neutralTemperature
  }

  function setTemperature(value) {
    var snapped = snapTemperature(value)
    // Neutral (6500) means off; keep the stored warm value for the next toggle.
    if (snapped >= neutralTemperature) {
      overrideActive(false)
      return
    }
    scheduledTemperature = snapped
    overrideActive(true)
  }

  function nudgeTemperature(direction) {
    saveTemperature(stepTemperature(stepIndexFor(temperature) + direction))
  }

  function saveTemperature(value) {
    setTemperature(value)
    saveSchedule()
  }

  function saveActive(value) {
    overrideActive(value)
    saveSchedule()
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

  // A manual change holds until the next boundary, then the schedule resumes.
  function overrideActive(value) {
    setActive(value)
    overrideUntil = scheduleEnabled ? ScheduleModel.nextBoundary(new Date(), warmFrom, normalAt) : 0
  }

  // Re-assert against an external writer (e.g. the nightlight shortcut): two
  // consecutive disagreements mean a stable external change. Skipped while our
  // own apply is in flight.
  function guardTemperature(reading) {
    if (!stateLoaded || applyProcess.running) return
    var match = String(reading).match(/[0-9]+/)
    // -1 never equals a real temperature, so a stopped daemon or bad reply counts as a disagreement.
    var current = match ? Number(match[0]) : -1
    var intended = temperature
    if (current === intended) {
      lastProbe = -1
      return
    }
    if (current === lastProbe) {
      lastProbe = -1
      applyTemperature(intended)
    } else {
      lastProbe = current
    }
  }

  // Schedule changed: take the current window and drop any override.
  function adoptSchedule() {
    if (!stateLoaded || !scheduleEnabled) return
    overrideUntil = 0
    scheduledPeriodActive = ScheduleModel.isScheduledPeriod(new Date(), warmFrom, normalAt)
    setActive(scheduledPeriodActive)
  }

  // The clock advanced.
  function followScheduleBoundary() {
    if (!stateLoaded || !scheduleEnabled) return
    if (overrideUntil > 0) {
      // Membership alone misses a shell suspended across a whole cycle: it wakes
      // inside the window it left. The override's expiry instant still catches it.
      if (new Date().getTime() < overrideUntil) return
      adoptSchedule()
      return
    }
    if (ScheduleModel.isScheduledPeriod(new Date(), warmFrom, normalAt) === scheduledPeriodActive) return
    adoptSchedule()
  }

  // Adopt only on a real edit: an edit is an explicit instruction, but
  // onEditingFinished also fires on plain focus loss.
  function applyScheduleEdit() {
    var edited = fromField.text !== warmFrom || toField.text !== normalAt
    if (!saveSchedule()) return
    if (edited) {
      adoptSchedule()
      saveSchedule()
      confirmSaved()
    }
  }

  function confirmSaved() {
    done = "Schedule saved."
    doneTimer.start()
  }

  function saveSchedule() {
    if (!ScheduleModel.isValidClock(fromField.text) || !ScheduleModel.isValidClock(toField.text)) {
      error = "Use 24-hour time, such as 19:00."
      return false
    }
    error = ""
    warmFrom = fromField.text
    normalAt = toField.text
    if (saveProcess.running) {
      saveQueued = true
      return true
    }
    saveProcess.command = ["python3", helper, "--set",
      "--enabled", scheduleEnabled ? "true" : "false",
      "--active", active ? "true" : "false",
      "--override-until", String(Math.max(0, Math.floor(overrideUntil))),
      "--temperature", String(scheduledTemperature),
      "--from", warmFrom, "--to", normalAt]
    saveProcess.running = true
    return true
  }

  function refresh() {
    if (!readProcess.running) readProcess.running = true
  }

  function loadState(text) {
    if (saveProcess.running || saveQueued) return
    try {
      var state = JSON.parse(text)
      var firstLoad = !stateLoaded
      scheduleEnabled = state.enabled
      overrideUntil = Math.max(0, Number(state.overrideUntil) || 0)
      scheduledTemperature = snapTemperature(state.temperature)
      // A stored neutral value would leave the toggle a silent no-op; heal it warm.
      if (scheduledTemperature >= neutralTemperature) scheduledTemperature = 4000
      warmFrom = state.from
      normalAt = state.to
      fromField.text = warmFrom
      toField.text = normalAt
      stateLoaded = true
      scheduledPeriodActive = ScheduleModel.isScheduledPeriod(new Date(), warmFrom, normalAt)
      if (firstLoad) {
        if (scheduleEnabled && (overrideUntil > new Date().getTime() || warmFrom === normalAt))
          setActive(state.active === true)
        else if (scheduleEnabled) {
          overrideUntil = 0
          setActive(scheduledPeriodActive)
        } else {
          overrideUntil = 0
          setActive(state.active === true)
        }
        // Push once even if `active` did not change, to bring a leftover hyprsunset into line.
        applyTemperature(temperature)
      }
      error = ""
    } catch (e) {
      error = "Could not read the Hyprsunset schedule."
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) refresh()
  Component.onCompleted: refresh()

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
    function refresh() { root.refresh() }
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

  Process {
    id: readProcess
    command: ["python3", root.helper]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadState(text)
    }
  }

  Process {
    id: applyProcess
    onExited: function(code) {
      root.applyFailed = code !== 0
      if (root.pendingTemperature >= 0) root.applyTemperature(root.pendingTemperature)
    }
  }

  Process {
    id: saveProcess
    onExited: function(code) {
      if (code !== 0) {
        root.error = "Could not save the Hyprsunset schedule."
        root.done = ""
        return
      }
      if (root.saveQueued) {
        root.saveQueued = false
        root.saveSchedule()
      }
    }
  }

  // External-writer guard probe; guardTemperature decides whether to re-assert.
  Process {
    id: probeProcess
    command: ["timeout", "1", "hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.guardTemperature(text)
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Timer {
    id: guardTimer
    interval: 2000
    repeat: true
    running: root.stateLoaded
    onTriggered: {
      if (!applyProcess.running && !probeProcess.running) probeProcess.running = true
    }
  }

  Timer {
    interval: 15000
    repeat: true
    running: root.stateLoaded
    onTriggered: root.followScheduleBoundary()
  }

  Timer {
    id: doneTimer
    interval: 2500
    onTriggered: root.done = ""
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
          id: temperatureSlider
          width: parent.width
          bar: root.bar
          minimum: 0
          maximum: root.temperatureSteps.length - 1
          step: 1
          integer: true
          tickCount: root.temperatureSteps.length
          value: root.stepIndexFor(root.temperature)
          onMoved: function(index) { root.setTemperature(root.stepTemperature(index)) }
          onReleased: function(index) { root.saveTemperature(root.stepTemperature(index)) }
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

      PanelSeparator { foreground: root.bar.foreground }

      Column {
        width: parent.width
        spacing: Style.space(8)

        Item {
          width: parent.width
          implicitHeight: Math.max(scheduleHeader.implicitHeight, scheduleSwitch.implicitHeight)
          PanelSectionHeader {
            id: scheduleHeader
            text: "SCHEDULE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }
          ToggleSwitch {
            id: scheduleSwitch
            checked: root.scheduleEnabled
            foreground: root.bar.foreground
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: {
              root.scheduleEnabled = !root.scheduleEnabled
              if (!root.scheduleEnabled) root.overrideUntil = 0
              // adoptSchedule reads in-memory state, no need to await the write
              if (root.saveSchedule() && root.scheduleEnabled) {
                root.adoptSchedule()
                root.saveSchedule()
              }
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(12)

          Column {
            width: Math.floor((parent.width - parent.spacing) / 2)
            spacing: Style.space(4)
            Text {
              text: "FROM"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            TimeField {
              id: fromField
              width: parent.width
              text: root.warmFrom
              placeholderText: "19:00"
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              onAccepted: root.applyScheduleEdit()
              onEditingFinished: root.applyScheduleEdit()
            }
          }

          Column {
            width: Math.floor((parent.width - parent.spacing) / 2)
            spacing: Style.space(4)
            Text {
              text: "TO"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            TimeField {
              id: toField
              width: parent.width
              text: root.normalAt
              placeholderText: "04:00"
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              onAccepted: root.applyScheduleEdit()
              onEditingFinished: root.applyScheduleEdit()
            }
          }
        }
      }

      Text {
        visible: root.error !== "" || root.applyFailed || root.done !== ""
        width: parent.width
        wrapMode: Text.Wrap
        text: root.applyFailed ? "Could not reach hyprsunset." : root.error !== "" ? root.error : root.done
        color: root.error !== "" || root.applyFailed ? root.bar.urgent : root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
