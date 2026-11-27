import Testing
@testable import TrimDiagram

@Suite("The clock of an animated diagram")
struct PlaybackClockTests {
    @Test("it runs with the clock from where it began")
    func runs() {
        let clock = PlaybackClock(now: 100)
        #expect(clock.time(now: 100) == 0)
        #expect(clock.time(now: 102.5) == 2.5)
    }

    @Test("paused it holds its time, and resuming carries on from it, not from the clock")
    func pauses() {
        var clock = PlaybackClock(now: 0)
        clock.pause(now: 3)
        #expect(clock.paused && clock.time(now: 3) == 3 && clock.time(now: 50) == 3)
        clock.resume(now: 50)
        #expect(!clock.paused && clock.time(now: 52) == 5)
        clock.toggle(now: 52)
        #expect(clock.paused && clock.time(now: 99) == 5)
        clock.toggle(now: 99)
        #expect(!clock.paused && clock.time(now: 100) == 6)
    }

    @Test("a seek moves it by seconds, never before the start, and keeps it paused or running as it was")
    func seeks() {
        var clock = PlaybackClock(now: 0)
        clock.seek(by: 4, now: 2)
        #expect(clock.time(now: 2) == 6 && clock.time(now: 3) == 7)
        clock.seek(by: -100, now: 3)
        #expect(clock.time(now: 3) == 0, "not before the start")
        clock.pause(now: 4)
        clock.seek(by: 2, now: 10)
        #expect(clock.paused && clock.time(now: 20) == 3)
    }

    @Test("restart goes to the start and runs from there, also when paused")
    func restarts() {
        var clock = PlaybackClock(now: 0)
        clock.restart(now: 9)
        #expect(clock.time(now: 11) == 2)
        clock.pause(now: 12)
        clock.restart(now: 20)
        #expect(clock.paused && clock.time(now: 30) == 0, "paused stays paused, at the start")
    }
}

@Suite("Seeking the clock of an animated diagram")
struct PlaybackClockSeekTests {
    @Test("seek to goes to a time, running or paused, and never before the start")
    func seekTo() {
        var clock = PlaybackClock(now: 0)
        clock.seek(to: 7, now: 3)
        #expect(clock.time(now: 3) == 7 && clock.time(now: 4) == 8)
        clock.pause(now: 4)
        clock.seek(to: 2, now: 9)
        #expect(clock.paused && clock.time(now: 50) == 2)
        clock.seek(to: -5, now: 9)
        #expect(clock.time(now: 9) == 0)
    }
}
