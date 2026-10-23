from dataclasses import fields

from meeting_notes.config import REPO_ROOT, WHISPER_FALLBACK, Config, resolve_whisper_model

FIELDS = [
    "notes_dir", "whisper_model", "languages", "initial_prompt", "glossary", "whisper_vad", "vad_split_gap",
    "whisper_temperature_fallback", "whisper_condition_on_previous_text", "whisper_max_chunk_sec",
    "mlx_cache_limit_mb", "diarization_models", "embedding_model", "cluster_threshold", "diarization_device",
    "diarization_engine", "fluidaudio_cli", "sherpa_embedding_model", "sherpa_cluster_threshold",
    "me_name", "mic_speakers", "mic_voice_check", "ollama_url", "ollama_model", "ollama_num_ctx", "ollama_keep_alive",
    "ollama_num_thread", "ollama_timeout_sec", "summary_chunk_chars", "summary_extract_chars", "summary_template",
    "summary_language", "ollama_preload", "priority", "cpu_threads", "diarization_batch_size", "keep_models_warm",
    "worker_idle_release_min", "live_min_chunk_sec", "live_max_chunk_sec", "live_pause_sec", "live_max_backlog_sec",
    "live_on_battery", "live_polish", "live_polish_pause_sec", "live_polish_max_words", "keep_wav", "rename_folder",
]


def test_whisper_default_is_turbo_q4_and_missing_local_path_falls_back(tmp_path, capsys):
    assert Config().whisper_model == "mlx-community/whisper-large-v3-turbo-q4"
    assert resolve_whisper_model("mlx-community/whisper-large-v3-mlx") == "mlx-community/whisper-large-v3-mlx"
    assert resolve_whisper_model(str(tmp_path / "missing-q4-mlx")) == WHISPER_FALLBACK
    assert "falling back" in capsys.readouterr().err
    local = tmp_path / "turbo-q4"
    local.mkdir()
    (local / "config.json").write_text("{}")
    assert resolve_whisper_model(str(local)) == str(local)


def test_config_load_resolves_whisper_model(tmp_path, monkeypatch):
    monkeypatch.setenv("MEETING_NOTES_WHISPER_MODEL", "~/definitely-missing-model-dir")
    assert Config.load(tmp_path / "none.toml").whisper_model == WHISPER_FALLBACK


def test_repo_root_has_pipeline_and_env_location():
    # hf_token() reads REPO_ROOT/.env: the root must be the directory that holds pipeline/ (and models/).
    assert (REPO_ROOT / "pipeline" / "pyproject.toml").is_file()
    assert (REPO_ROOT / "AGENTS.md").is_file()


def test_config_field_names_are_the_public_keys():
    # config.toml keys are public API (README, config.example.toml, the app): renaming one breaks users.
    assert [f.name for f in fields(Config)] == FIELDS


def _prefs(tmp_path, **values):
    import plistlib

    path = tmp_path / "prefs.plist"
    path.write_bytes(plistlib.dumps(values, fmt=plistlib.FMT_BINARY))
    return path


def test_app_notes_folder_is_the_single_source(tmp_path, monkeypatch):
    from meeting_notes.config import load_config

    monkeypatch.delenv("MEETING_NOTES_DIR", raising=False)
    toml = tmp_path / "config.toml"
    toml.write_text('notes_dir = "~/FromToml"\n')
    prefs = _prefs(tmp_path, notesDir="/Users/demo/Work notes", uiLanguage="vi")
    assert load_config(toml, app_prefs=prefs).notes_dir == "/Users/demo/Work notes"
    # The app removes the key when it uses its default: config.toml (or the default) applies.
    assert load_config(toml, app_prefs=_prefs(tmp_path, uiLanguage="en")).notes_dir == "~/FromToml"
    assert load_config(toml, app_prefs=tmp_path / "missing.plist").notes_dir == "~/FromToml"
    # The environment (set by the app for its worker) still wins.
    monkeypatch.setenv("MEETING_NOTES_DIR", "/env/notes")
    assert load_config(toml, app_prefs=prefs).notes_dir == "/env/notes"


def test_unreadable_app_prefs_are_ignored(tmp_path, monkeypatch):
    from meeting_notes.config.loader import app_notes_dir

    broken = tmp_path / "broken.plist"
    broken.write_bytes(b"not a plist")
    assert app_notes_dir(broken) is None
    assert app_notes_dir(_prefs(tmp_path, notesDir="   ")) is None
    monkeypatch.setenv("MEETING_NOTES_APP_PREFS", str(_prefs(tmp_path, notesDir="~/X")))
    assert app_notes_dir() == "~/X"
