import QtQuick
import QtQuick.Controls
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
  // The toggle owns `active` outright. Deriving it from the hyprsunset probe
  // instead means a dead or slow daemon reports the old temperature back and
  // silently undoes the toggle, which is what used to happen.
  property bool active: false
  property int scheduledTemperature: 3000
  property bool scheduleEnabled: true
  property string warmFrom: "19:00"
  property string normalAt: "04:00"
  property string error: ""
  property bool stateLoaded: false
  property bool scheduledPeriodActive: false
  property bool saveQueued: false
  property int pendingTemperature: -1
  // Epoch ms at which a manual override hands control back to the schedule.
  // 0 means the schedule is in charge.
  property real overrideUntil: 0
  property bool applyFailed: false

  readonly property int neutralTemperature: temperatureSteps[temperatureSteps.length - 1]
  readonly property int temperature: active ? scheduledTemperature : neutralTemperature

  // One apply per state change, no ramp: a ramp used to fire ~25 `hyprctl` calls
  // per toggle, which raced the daemon start and left duplicate hyprsunsets
  // contending for one socket.
  onTemperatureChanged: if (stateLoaded) applyTemperature(temperature)
  readonly property string temperatureName: nameForTemperature(temperature)

  function nameForTemperature(value) {
    if (value >= 6000) return "NEUTRAL"
    if (value >= 4500) return "SOFT"
    if (value >= 3200) return "WARM"
    return "AMBER"
  }

  // hyprsunset dislikes a firehose of temperature changes, so the slider only
  // stops on these values instead of sweeping continuously.
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
    scheduledTemperature = snapTemperature(value)
    overrideActive(true)
  }

  function nudgeTemperature(direction) {
    saveTemperature(stepTemperature(stepIndexFor(temperature) + direction))
  }

  function saveTemperature(value) {
    setTemperature(value)
    saveSchedule()
  }

  // This plugin is the sole writer of the hyprsunset temperature:
  // omarchy.nightlight is in shell.json's disabledPlugins, so nothing else
  // applies a value behind it.
  //
  // The temperature arrives as $1 rather than being pasted into the script, so
  // the script itself is a constant.
  readonly property string applyScript:
    "t=$1; " +
    // Every call is bounded: a daemon stopped mid-syscall accepts the
    // connection and never replies, which hangs hyprctl instead of failing it.
    "h() { timeout 1 hyprctl hyprsunset $1 $2 2>/dev/null; }; " +
    // `pgrep` cannot tell a healthy daemon from one whose socket has stopped
    // answering, so the command itself is the test. Read the value back as
    // well: a freshly started hyprsunset applies its own default at the end of
    // boot and overwrites anything set before then.
    "ok() { h temperature $t >/dev/null && [ x$(h temperature | grep -oE '[0-9]+' | head -n1) = x$t ]; }; " +
    "ok && exit 0; " +
    // Replace the daemon instead of adding one -- two of them contending for
    // the same socket is what wedged it. SIGKILL because a stopped process
    // leaves SIGTERM pending forever.
    "pkill -KILL -x hyprsunset; " +
    "setsid uwsm-app -- hyprsunset >/dev/null 2>&1 & " +
    // Bounded by wall clock, not by attempts, so a machine where hyprsunset
    // never starts fails in seconds rather than minutes.
    "end=$((SECONDS+8)); " +
    "while [ $SECONDS -lt $end ]; do sleep 0.3; ok && exit 0; done; " +
    "exit 1"

  // One `hyprctl` at a time. A value arriving mid-apply replaces any earlier
  // pending one, so a slider drag collapses to where it stopped.
  function applyTemperature(value) {
    if (applyProcess.running) {
      pendingTemperature = value
      return
    }
    pendingTemperature = -1
    applyProcess.command = ["bash", "-lc", applyScript, "screen-temperature", String(value)]
    applyProcess.running = true
  }

  // A manual change holds until the next schedule boundary, then the schedule
  // resumes control.
  function overrideActive(value) {
    setActive(value)
    overrideUntil = ScheduleModel.nextBoundary(new Date(), warmFrom, normalAt)
  }

  // The user changed the schedule, so take the window that applies right now
  // and drop any override along with it.
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
      // Membership alone cannot see this: a shell suspended across a whole
      // cycle wakes inside the window it left, having crossed two boundaries.
      // The override's own expiry instant can.
      if (new Date().getTime() < overrideUntil) return
      adoptSchedule()
      return
    }
    if (ScheduleModel.isScheduledPeriod(new Date(), warmFrom, normalAt) === scheduledPeriodActive) return
    adoptSchedule()
  }

  // Codex finding: editing FROM or TO inside the current window left a manual
  // override standing, because membership had not changed. An edit is an
  // explicit instruction, so the schedule takes over -- but only on a real
  // edit, since onEditingFinished also fires on plain focus loss.
  function applyScheduleEdit() {
    var edited = fromField.text !== warmFrom || toField.text !== normalAt
    if (!saveSchedule()) return
    if (edited) adoptSchedule()
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
      scheduledTemperature = snapTemperature(state.temperature)
      warmFrom = state.from
      normalAt = state.to
      fromField.text = warmFrom
      toField.text = normalAt
      stateLoaded = true
      scheduledPeriodActive = ScheduleModel.isScheduledPeriod(new Date(), warmFrom, normalAt)
      if (firstLoad) {
        if (scheduleEnabled) setActive(scheduledPeriodActive)
        // `active` may not have changed, so push the temperature once on startup
        // to bring a hyprsunset left over from a previous session into line.
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

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): string {
      root.overrideActive(!root.active)
      return root.active ? "enabled" : "disabled"
    }
    function status(): string {
      return JSON.stringify({ enabled: root.active, temperature: root.temperature })
    }
  }

  // omarchy.nightlight is disabled in favour of this plugin, so its IPC target
  // moves here. `omarchy-toggle-nightlight` and anything else built on it keeps
  // resolving, against a single owner of the daemon.
  IpcHandler {
    target: "nightlight"

    function status(): string {
      return JSON.stringify({ enabled: root.active, temperature: root.temperature })
    }
    function refresh(): void { root.refresh() }
    function enable(): string {
      root.overrideActive(true)
      return root.active ? "enabled" : "disabled"
    }
    function disable(): string {
      root.overrideActive(false)
      return "disabled"
    }
    function toggle(): string {
      root.overrideActive(!root.active)
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
        return
      }
      if (root.saveQueued) {
        root.saveQueued = false
        root.saveSchedule()
      }
    }
  }

  Timer {
    interval: 15000
    repeat: true
    running: root.stateLoaded
    onTriggered: root.followScheduleBoundary()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖔"
    active: root.active
    tooltipText: root.temperature + "K screen temperature"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.overrideActive(!root.active)
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
          onToggled: root.overrideActive(!root.active)
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
              // adoptSchedule reads in-memory state, so it need not await the write
              if (root.saveSchedule()) root.adoptSchedule()
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
            TextField {
              id: fromField
              width: parent.width
              text: root.warmFrom
              placeholderText: "19:00"
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              inputMethodHints: Qt.ImhTime
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
            TextField {
              id: toField
              width: parent.width
              text: root.normalAt
              placeholderText: "04:00"
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              inputMethodHints: Qt.ImhTime
              onAccepted: root.applyScheduleEdit()
              onEditingFinished: root.applyScheduleEdit()
            }
          }
        }
      }

      Text {
        visible: root.error !== "" || root.applyFailed
        width: parent.width
        wrapMode: Text.Wrap
        text: root.applyFailed ? "Could not reach hyprsunset." : root.error
        color: root.bar.urgent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
