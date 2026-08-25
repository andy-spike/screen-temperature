// The fixed steps every applied temperature lands on, shared by Panel.qml and
// the test. hyprsunset dislikes a firehose of changes, so the slider and the
// wheel both stop on these rather than sweeping. The module.exports guard at
// the bottom lets one file be imported by QML and required by node.

var steps = [2000, 2500, 3000, 3500, 4000, 4500, 5000, 5500, 6000, 6500]

// The top step is neutral: the filter is off.
function neutral() {
  return steps[steps.length - 1]
}

// Nearest step to a raw value. A value exactly between two steps takes the
// lower one, so the result is stable rather than drifting up on repeat snaps.
function indexFor(value) {
  var best = 0
  for (var i = 1; i < steps.length; i++)
    if (Math.abs(steps[i] - value) < Math.abs(steps[best] - value)) best = i
  return best
}

function at(index) {
  return steps[Math.max(0, Math.min(steps.length - 1, index))]
}

function snap(value) {
  return steps[indexFor(value)]
}

// One step up or down, clamped at both ends.
function stepFrom(value, direction) {
  return at(indexFor(value) + direction)
}

function nameFor(value) {
  if (value >= 6000) return "NEUTRAL"
  if (value >= 4500) return "SOFT"
  if (value >= 3200) return "WARM"
  return "AMBER"
}

if (typeof module !== "undefined") {
  module.exports = {
    steps: steps,
    neutral: neutral,
    indexFor: indexFor,
    at: at,
    snap: snap,
    stepFrom: stepFrom,
    nameFor: nameFor
  }
}
