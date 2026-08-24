// Pure schedule arithmetic, shared by Panel.qml and test_schedule_model.js.
// The `module.exports` guard at the bottom mirrors omarchy's own
// shell/plugins/services/nightlight/NightlightModel.js, so one file can be
// imported by QML and required by node.

function isValidClock(value) {
  return /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(value)
}

function clockMinutes(value) {
  var parts = String(value).split(":")
  return Number(parts[0]) * 60 + Number(parts[1])
}

// A window may wrap midnight, as 19:00 -> 04:00 does. from === to means there
// is no window at all.
function isScheduledPeriod(date, from, to) {
  var now = date.getHours() * 60 + date.getMinutes()
  var start = clockMinutes(from)
  var end = clockMinutes(to)
  if (start === end) return false
  return start < end ? now >= start && now < end : now >= start || now < end
}

// Epoch ms of the first boundary strictly after `date`, or 0 when the schedule
// has no boundaries. A manual override expires at this instant.
//
// Comparing window membership is not enough on its own: a shell suspended
// across a whole cycle wakes with the membership it went to sleep with, having
// crossed two boundaries in between.
function nextBoundary(date, from, to) {
  var start = clockMinutes(from)
  var end = clockMinutes(to)
  if (start === end) return 0
  var candidates = [start, end]
  var soonest = 0
  for (var i = 0; i < candidates.length; i++) {
    var at = new Date(date.getTime())
    at.setHours(Math.floor(candidates[i] / 60), candidates[i] % 60, 0, 0)
    if (at.getTime() <= date.getTime()) at.setDate(at.getDate() + 1)
    if (soonest === 0 || at.getTime() < soonest) soonest = at.getTime()
  }
  return soonest
}

if (typeof module !== "undefined") {
  module.exports = {
    isValidClock: isValidClock,
    clockMinutes: clockMinutes,
    isScheduledPeriod: isScheduledPeriod,
    nextBoundary: nextBoundary
  }
}
