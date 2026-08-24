const assert = require("assert")
const model = require("./ScheduleModel.js")

const at = (hour, minute, second = 0) => new Date(2026, 7, 24, hour, minute, second)
const inWindow = (date, from = "19:00", to = "04:00") =>
  model.isScheduledPeriod(date, from, to)

// Clock parsing
assert.strictEqual(model.clockMinutes("19:00"), 1140)
assert.strictEqual(model.clockMinutes("00:00"), 0)
assert.ok(model.isValidClock("23:59"))
assert.ok(!model.isValidClock("24:00"))
assert.ok(!model.isValidClock("99:00"))
assert.ok(!model.isValidClock("7:00"))

// A window that wraps midnight
assert.ok(inWindow(at(19, 0)), "start is inclusive")
assert.ok(inWindow(at(23, 59)))
assert.ok(inWindow(at(3, 59)))
assert.ok(!inWindow(at(4, 0)), "end is exclusive")
assert.ok(!inWindow(at(9, 14)))
assert.ok(!inWindow(at(18, 59)))

// A window inside one day
assert.ok(inWindow(at(9, 0), "08:00", "10:00"))
assert.ok(!inWindow(at(7, 59), "08:00", "10:00"))
assert.ok(!inWindow(at(10, 0), "08:00", "10:00"))

// An empty window is never active and has no boundaries
assert.ok(!inWindow(at(12, 0), "19:00", "19:00"))
assert.strictEqual(model.nextBoundary(at(12, 0), "19:00", "19:00"), 0)

// The next boundary, which is when a manual override expires
const boundary = (date, from = "19:00", to = "04:00") =>
  new Date(model.nextBoundary(date, from, to))
assert.strictEqual(boundary(at(9, 14)).getHours(), 19)
assert.strictEqual(boundary(at(20, 0)).getHours(), 4)
assert.strictEqual(boundary(at(20, 0)).getDate(), 25, "wraps to the next day")
assert.strictEqual(boundary(at(3, 0)).getHours(), 4)

// Standing exactly on a boundary must yield the *other* one, otherwise an
// override taken at 19:00 would expire the instant it was made.
assert.strictEqual(boundary(at(19, 0)).getHours(), 4)
assert.strictEqual(boundary(at(4, 0)).getHours(), 19)

// Seconds are truncated, so the boundary lands on the minute
assert.strictEqual(boundary(at(18, 59, 45)).getTime(), at(19, 0).getTime())

// An override taken inside the window expires at the far edge, not before
assert.ok(model.nextBoundary(at(19, 30), "19:00", "04:00") > at(19, 30).getTime())
const tomorrowAt4 = new Date(2026, 7, 25, 4, 0, 0).getTime()
assert.strictEqual(boundary(at(19, 30)).getTime(), tomorrowAt4)

console.log("test_schedule_model.js: PASS")
