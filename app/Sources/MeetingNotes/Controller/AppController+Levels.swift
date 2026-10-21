// 1 Hz tick while recording and the level meter sampling (Controller).

import AppKit
import MeetingNotesCore
import MeetingNotesUI

extension AppController {
    func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    func tick() {
        guard let session else { return }
        let elapsed = Format.elapsed(session.recordedSeconds)
        if clock.elapsed != elapsed { clock.elapsed = elapsed }
        guard machine.phase == .recording else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let micDB = session.micWriter?.meter.takeWindowMaxDB() ?? LevelMeter.floorDB
        let systemDB = session.systemWriter?.meter.takeWindowMaxDB() ?? LevelMeter.floorDB
        var health = SystemAudioHealth.notPermitted
        if session.systemAudioAvailable {
            _ = systemSilence.update(now: now, levelDB: systemDB)
            health = systemSilence.silentDuration(now: now) >= 10 ? .silent : .ok
        }
        if systemAudio != health { systemAudio = health }

        if autoStop == nil, silence.update(now: now, levelDB: max(micDB, systemDB)) {
            promptAutoStop(AutoStopPrompt(reason: tr(.autoStopSilence, Settings.autoStopSilenceMinutes), remaining: 60, appEnded: false))
        } else if var prompt = autoStop {
            prompt.remaining -= 1
            if prompt.remaining <= 0 {
                dismissAutoStop()
                perform(.stop, source: .autoStop)
            } else {
                autoStop = prompt
                ui?.showAutoStopCard(prompt)
            }
        }
    }

    /// A meter surface became visible or hidden.
    func setMeterVisible(_ id: String, _ visible: Bool) {
        if visible { meterConsumers.insert(id) } else { meterConsumers.remove(id) }
        updateLevelTimer()
    }

    /// <= 12 fps, only while recording and at least one meter is on screen.
    func updateLevelTimer() {
        let needed = machine.phase == .recording && !meterConsumers.isEmpty
        if needed, levelTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleLevels() }
            }
            timer.tolerance = 0.03
            RunLoop.main.add(timer, forMode: .common)
            levelTimer = timer
        } else if !needed, let timer = levelTimer {
            timer.invalidate()
            levelTimer = nil
            sampleLevels()  // resets to 0 when not recording
        }
    }

    private func sampleLevels() {
        guard let session, machine.phase == .recording else {
            resetLevels()
            return
        }
        let me = LevelMeter.displayValue(session.micWriter?.meter.level() ?? 0)
        let them = LevelMeter.displayValue(session.systemWriter?.meter.level() ?? 0)
        if abs(levels.me - me) > 0.01 { levels.me = me }
        if abs(levels.them - them) > 0.01 { levels.them = them }
    }

    func resetLevels() {
        if levels.me != 0 { levels.me = 0 }
        if levels.them != 0 { levels.them = 0 }
    }
}
