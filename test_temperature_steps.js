const assert = require("assert")
const Steps = require("./TemperatureSteps.js")

assert.strictEqual(Steps.neutral(), 6500)

// Snapping to the nearest step
assert.strictEqual(Steps.snap(4000), 4000)
assert.strictEqual(Steps.snap(4100), 4000)
assert.strictEqual(Steps.snap(4400), 4500)
assert.strictEqual(Steps.snap(4250), 4000, "a value between two steps takes the lower one")
assert.strictEqual(Steps.snap(100), 2000, "below the range clamps to the first step")
assert.strictEqual(Steps.snap(9000), 6500, "above the range clamps to neutral")

// Stepping, which is what the wheel does
assert.strictEqual(Steps.stepFrom(6500, -1), 6000)
assert.strictEqual(Steps.stepFrom(6000, 1), 6500)
assert.strictEqual(Steps.stepFrom(2000, -1), 2000, "cannot step below the warmest")
assert.strictEqual(Steps.stepFrom(6500, 1), 6500, "cannot step past neutral")

// The name shown under the title
assert.strictEqual(Steps.nameFor(6500), "NEUTRAL")
assert.strictEqual(Steps.nameFor(6000), "NEUTRAL")
assert.strictEqual(Steps.nameFor(4500), "SOFT")
assert.strictEqual(Steps.nameFor(3500), "WARM")
assert.strictEqual(Steps.nameFor(2000), "AMBER")

console.log("test_temperature_steps.js: PASS")
