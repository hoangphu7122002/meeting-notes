from meeting_notes.domain.live_backlog import DEFER, PROCESS, SKIP, BacklogPolicy, LoadSample, decide, status_of

NORMAL = LoadSample(memory_pressure=1, cpu_busy=0.2, thermal=0, on_battery=False)


def test_process_when_idle_and_under_backlog():
    d = decide(30, NORMAL, BacklogPolicy())
    assert d.action == PROCESS and status_of(d) == "running"


def test_defer_under_memory_cpu_or_thermal_pressure():
    for load, reason in [(LoadSample(4, 0.2, 0), "memory"),
                         (LoadSample(1, 0.95, 0), "cpu"), (LoadSample(1, 0.2, 2), "thermal")]:
        d = decide(10, load, BacklogPolicy())
        assert (d.action, d.reason, status_of(d)) == (DEFER, reason, "deferred")
    assert decide(10, LoadSample(0, 0.2, 1), BacklogPolicy()).action == PROCESS  # unknown pressure, moderate heat


def test_skip_beyond_backlog_and_on_battery_unless_allowed():
    d = decide(121, LoadSample(2, 0.2, 0), BacklogPolicy(max_backlog_sec=120))
    assert (d.action, d.reason, status_of(d)) == (SKIP, "backlog", "throttled")
    battery = LoadSample(1, 0.1, 0, on_battery=True)
    assert decide(5, battery, BacklogPolicy()).reason == "battery"
    assert decide(5, battery, BacklogPolicy(on_battery=True)).action == PROCESS


def test_memory_pause_level_normal_warn_critical_by_setting():
    from meeting_notes.domain.live_backlog import pause_pressure_level
    crit, warn = BacklogPolicy(), BacklogPolicy(pause_pressure=pause_pressure_level("warn"))
    assert BacklogPolicy().pause_pressure == 4 and pause_pressure_level("bogus") == 4
    for level, on_crit, on_warn in [(1, PROCESS, PROCESS), (2, PROCESS, DEFER), (4, DEFER, DEFER), (0, PROCESS, PROCESS)]:
        assert decide(10, LoadSample(level, 0.2, 0), crit).action == on_crit
        assert decide(10, LoadSample(level, 0.2, 0), warn).action == on_warn
    assert decide(10, LoadSample(2, 0.2, 0, on_battery=True), crit).reason == "battery"
