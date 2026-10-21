"""Architecture rules, checked on the source with `ast` (function-level and lazy imports included).

Layers (dependencies point down only):

    entrypoints          wires everything together
    adapters.inbound     driven by the user or the app (CLI commands, worker)
    adapters.outbound    one vendor or sink per file (ffmpeg, pyannote, mlx, ollama, disk, ...)
    application          use cases and their ports
    domain               pure rules: stdlib + numpy/scipy, no config, no I/O
    config               settings kernel (stdlib only); application and adapters may use it, domain may not

Run: `make lint-arch` or `uv run pytest tests/architecture -q`.
"""

from __future__ import annotations

import ast
import subprocess
import sys
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parents[2] / "src"
PACKAGE = "meeting_notes"
MAX_LINES = 300

STDLIB = set(sys.stdlib_module_names)
# Stdlib modules a pure layer may use (no I/O, no processes, no network, no clock beyond datetime).
PURE_STDLIB = {"__future__", "re", "unicodedata", "math", "collections", "dataclasses", "datetime", "typing", "json"}
# The application layer additionally orchestrates files and runs: paths, pid, timing, tracebacks.
APPLICATION_STDLIB = PURE_STDLIB | {"os", "pathlib", "time", "traceback"}
VALUE_LIBS = {"numpy", "scipy"}  # numeric value libraries: allowed in domain and application
HEAVY_LIBS = {"mlx", "mlx_whisper", "torch", "pyannote", "huggingface_hub", "soundfile"}
# Heavy model/audio libs that must never load at CLI import (numpy/scipy are value libs, checked separately).
CLI_BANNED = HEAVY_LIBS | {"numpy", "scipy"}
IO_STDLIB = {"subprocess", "urllib", "shutil", "ctypes"}

# layer -> layers it may import from
ALLOWED = {
    "domain": {"domain"},
    "config": {"config"},
    "application": {"application", "domain", "config"},
    "outbound": {"outbound", "application", "domain", "config"},
    "inbound": {"inbound", "application", "domain", "config"},
    "entrypoints": {"entrypoints", "inbound", "outbound", "application", "domain", "config"},
}


def layer_of(module: str) -> str | None:
    parts = module.split(".")
    if parts[0] != PACKAGE or len(parts) < 2:
        return None
    if parts[1] == "adapters":
        return parts[2] if len(parts) > 2 and parts[2] in ("inbound", "outbound") else None
    return parts[1] if parts[1] in ALLOWED else None


def source_files() -> list[tuple[str, Path]]:
    out = []
    for path in sorted((SRC / PACKAGE).rglob("*.py")):
        rel = path.relative_to(SRC).with_suffix("")
        parts = list(rel.parts)
        if parts[-1] == "__init__":
            parts.pop()
        out.append((".".join(parts), path))
    return out


def imports_of(module: str, path: Path) -> list[tuple[str, int]]:
    """Absolute module names imported by a file (relative imports resolved), with line numbers."""
    is_package = path.name == "__init__.py"
    base = module.split(".") if is_package else module.split(".")[:-1]
    found: list[tuple[str, int]] = []
    for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
        if isinstance(node, ast.Import):
            found += [(alias.name, node.lineno) for alias in node.names]
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                anchor = base[: len(base) - (node.level - 1)]
                name = ".".join(anchor + ([node.module] if node.module else []))
            else:
                name = node.module or ""
            found.append((name, node.lineno))
            # `from ..adapters import outbound` names the layer only in the alias.
            found += [(f"{name}.{alias.name}", node.lineno) for alias in node.names if alias.name != "*"]
    return found


FILES = source_files()


def violations(check) -> list[str]:
    out = []
    for module, path in FILES:
        layer = layer_of(module)
        for name, line in imports_of(module, path):
            problem = check(module, layer, name)
            if problem:
                out.append(f"{path.relative_to(SRC)}:{line}: {problem} (imports {name})")
    return out


def test_every_module_belongs_to_a_layer():
    stray = [m for m, _ in FILES if m != PACKAGE and layer_of(m) is None and m.count(".") > 0
             and m not in (f"{PACKAGE}.adapters",)]
    assert not stray, f"modules outside config/domain/application/adapters/entrypoints: {stray}"


def test_layers_import_only_downwards():
    def check(module, layer, name):
        target = layer_of(name)
        if layer and target and target not in ALLOWED[layer]:
            return f"{layer} must not import {target}"

    assert not violations(check)


def test_inbound_and_outbound_adapters_never_import_each_other():
    def check(module, layer, name):
        if {layer, layer_of(name)} == {"inbound", "outbound"}:
            return "inbound and outbound adapters must not import each other"

    assert not violations(check)


def test_domain_is_pure():
    def check(module, layer, name):
        if layer != "domain" or layer_of(name):
            return None
        top = name.split(".")[0]
        if top in VALUE_LIBS or top in PURE_STDLIB:
            return None
        return "domain may import only pure stdlib, numpy/scipy and other domain modules"

    assert not violations(check)


def test_application_uses_only_domain_config_ports_and_value_libs():
    def check(module, layer, name):
        if layer != "application" or layer_of(name):
            return None
        top = name.split(".")[0]
        if top in VALUE_LIBS or top in APPLICATION_STDLIB:
            return None
        return "application may import only domain, config, its own ports, numpy and light stdlib"

    assert not violations(check)


def test_config_imports_only_stdlib():
    def check(module, layer, name):
        if layer == "config" and not layer_of(name) and name.split(".")[0] not in STDLIB:
            return "config may import only the stdlib"

    assert not violations(check)


def test_inbound_adapters_use_no_third_party_libs():
    def check(module, layer, name):
        top = name.split(".")[0]
        if layer == "inbound" and not layer_of(name) and top not in STDLIB and top != PACKAGE:
            return "inbound adapters stay free of third-party libraries"

    assert not violations(check)


def test_heavy_libs_and_io_stdlib_stay_in_outbound_adapters():
    def check(module, layer, name):
        top = name.split(".")[0]
        if layer not in ("outbound", "entrypoints") and (top in HEAVY_LIBS or top in IO_STDLIB):
            return f"{top} is for adapters/outbound (or entrypoints) only"

    assert not violations(check)


def test_adapters_import_heavy_libs_only_inside_functions():
    """Module top level stays light so adapters can be imported (and typed against) without the ML stack."""
    out = []
    for module, path in FILES:
        if layer_of(module) not in ("outbound", "inbound"):
            continue
        for node in ast.parse(path.read_text(encoding="utf-8")).body:
            names = []
            if isinstance(node, ast.Import):
                names = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom) and not node.level:
                names = [node.module or ""]
            out += [f"{path.relative_to(SRC)}:{node.lineno}: top-level import of {n}" for n in names if n.split(".")[0] in HEAVY_LIBS]
    assert not out, "\n".join(out)


def test_no_import_cycles_between_layers():
    graph: dict[str, set[str]] = {layer: set() for layer in ALLOWED}
    for module, path in FILES:
        layer = layer_of(module)
        for name, _ in imports_of(module, path):
            target = layer_of(name)
            if layer and target and target != layer:
                graph[layer].add(target)
    state: dict[str, int] = {}

    def visit(node: str, trail: list[str]) -> None:
        assert state.get(node) != 1, f"import cycle: {' -> '.join([*trail, node])}"
        if state.get(node) == 2:
            return
        state[node] = 1
        for nxt in sorted(graph[node]):
            visit(nxt, [*trail, node])
        state[node] = 2

    for layer in graph:
        visit(layer, [])


def test_source_files_stay_small():
    big = {str(p.relative_to(SRC)): n for _, p in FILES if (n := len(p.read_text(encoding="utf-8").splitlines())) > MAX_LINES}
    assert not big, f"files over {MAX_LINES} lines: {big}"


@pytest.mark.parametrize("modules", [["meeting_notes.entrypoints.cli"],
                                     ["meeting_notes.entrypoints.cli", "meeting_notes.entrypoints.wiring"]])
def test_cli_import_loads_no_heavy_libs(modules):
    """Importing the CLI (and building the command deps) must stay cheap: no ML stack, no numpy."""
    code = (
        "import sys\n"
        + "".join(f"import {m}\n" for m in modules)
        + "from meeting_notes.entrypoints import wiring\n"
        + "wiring.command_deps()\n"
        + f"banned = set({sorted(CLI_BANNED)!r})\n"
        + "loaded = sorted({m.split('.')[0] for m in sys.modules} & banned)\n"
        + "print(','.join(loaded))\n"
    )
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True)
    assert out.stdout.strip() == "", f"heavy libraries loaded at CLI import: {out.stdout.strip()}"
