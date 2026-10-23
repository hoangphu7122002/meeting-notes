from meeting_notes.domain.warm_policy import AUTO, OFF, ON, keep_warm, warm_mode


def test_warm_mode_normalizes_config_values():
    assert [warm_mode(v) for v in (True, "on", "TRUE", False, "off", None, "auto", "bogus")] == [
        ON, ON, ON, OFF, OFF, OFF, AUTO, AUTO]


def test_auto_keeps_only_under_normal_pressure():
    assert keep_warm(AUTO, 1)
    assert not any(keep_warm(AUTO, p) for p in (0, 2, 4))  # unknown counts as pressure: RAM safety first


def test_on_keeps_unless_critical_and_off_never_keeps():
    assert keep_warm(ON, 0) and keep_warm(ON, 2) and not keep_warm(ON, 4)
    assert not any(keep_warm(OFF, p) for p in (0, 1, 2, 4))
