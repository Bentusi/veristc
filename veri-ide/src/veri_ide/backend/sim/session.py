"""
One simulation run: the chart's text, the station's object table, the frames back.

`veri-runtime/sim` is the only thing that decides what a value is. This module
compiles the composed text, hands over the `.plant` table derived from the same
station configuration the compiler was given, runs `sim --watch` and keeps the
frames as they came: address, type, size, channel and raw stay beside each value,
so what a chart shows is what the run reported.

The name table is capped at 16 symbols per run (protocol section 4.6), so a
bigger chart is split over several runs. That is safe rather than a fudge: the
protocol guarantees the same image, table and parameters produce the same stream
cycle for cycle, so the runs line up by cycle number.

Stimulus (protocol section 5) rides along the same way: `--force` for an
immediate override and `--script` for values that land on a given cycle. The
frames carry which of the watched symbols were overridden, so a forced value is
never drawn as if the program had worked it out.
"""

import json
import math
import re
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from ..build.service import Diagnostic, find_veristc_binary, parse_ndjson_diagnostics

#: `spec/simulation-spec.md` 4.6 -- more names than this and `sim` refuses to start.
WATCH_NAMES_PER_RUN = 16
#: Same section: a name of 64 bytes or more is refused.
WATCH_NAME_MAX_BYTES = 63
#: Section 5: the runner's tables are static, so both caps are refused up front
#: instead of letting a request be silently truncated.
FORCE_MAX_TARGETS = 64
FORCE_MAX_RECORDS = 64
#: Section 5.1: the shape of a value token. Whether a REAL-only form (a decimal)
#: is admissible for a given symbol is the simulator's call, not this module's.
VALUE_TOKEN = re.compile(
    r"^(?:-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?|TRUE|FALSE)$", re.IGNORECASE
)


class SimError(ValueError):
    """A tool could not be run, or its output could not be read."""


def format_stimulus_value(name: str, value: Any) -> str:
    """The token `sim` is handed for an override of `name`.

    Only the shape is checked here. Whether the value fits the symbol's type and
    the channel's physical range is decided by the runner, which refuses at
    startup rather than coercing -- and a token carrying a comma or an equals
    sign would become a different record than the one the engineer typed.
    """
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, float):
        if not math.isfinite(value):
            raise SimError(f"force {name}: {value!r} is not a finite number")
        token = repr(value)
    elif isinstance(value, int):
        token = str(value)
    else:
        token = str(value).strip()
    if not VALUE_TOKEN.match(token):
        raise SimError(f"force {name}: {token!r} is neither a number nor TRUE/FALSE")
    return token


def _check_stimulus_name(name: str) -> str:
    if not isinstance(name, str) or not name.strip():
        raise SimError("a stimulus record needs the symbol name it overrides")
    text = name.strip()
    if len(text.encode()) > WATCH_NAME_MAX_BYTES:
        raise SimError(f"force {text}: name longer than {WATCH_NAME_MAX_BYTES} bytes")
    if re.search(r"[\s,=]", text):
        raise SimError(f"force {text}: a symbol name may not contain spaces, commas or '='")
    return text


def find_sim_binary(explicit: Optional[Path] = None) -> Path:
    """The `sim` executable of the runtime build tree."""
    candidates = [explicit] if explicit is not None else []
    candidates.extend([_repo_build_bin() / "sim", Path("build/bin/sim")])
    for candidate in candidates:
        if candidate is not None and candidate.is_file():
            return candidate
    raise FileNotFoundError(
        "sim binary not found; build it with: make -C veri-runtime build-sim"
    )


def _repo_build_bin() -> Path:
    """The repository's `build/bin`, found by walking up from this module."""
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "build" / "bin"
        if candidate.is_dir():
            return candidate
    return here.parents[4] / "build" / "bin"


@dataclass
class Series:
    """One watched symbol over the run, with the frame keys kept beside it."""

    name: str
    addr: int
    type: str
    size: int
    channel: Optional[int]
    values: list[Any] = field(default_factory=list)
    raw: list[Any] = field(default_factory=list)
    forced: list[bool] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "addr": self.addr,
            "type": self.type,
            "size": self.size,
            "channel": self.channel,
            "values": self.values,
            "raw": self.raw,
            "forced": self.forced,
        }


@dataclass
class SimRun:
    ok: bool
    payload: dict
    errors: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return self.payload


def run_simulation(
    st_text: str,
    plant_text: str,
    names: list[str],
    *,
    cycles: int,
    cycle_ms: int,
    forces: Optional[list[dict]] = None,
    script: Optional[list[dict]] = None,
    sim_binary: Optional[Path] = None,
    veristc_binary: Optional[Path] = None,
    timeout_s: int = 60,
) -> SimRun:
    """
    Compile `st_text`, simulate it against `plant_text`, return the timelines.

    `forces` is a list of `{name, value}` overrides that hold from the first
    cycle, `script` a list of `{cycle, name, value}` records that take over from
    it -- both are the protocol's own two shapes, handed to `sim` unchanged.

    A refusal is reported, never papered over: a compile error, a rejected
    `.plant` row, a program/object mismatch, a rejected override and a stream
    that ends without its done frame each come back as a named error carrying
    the tool's own words.
    """
    names = sorted(set(names))
    if not names:
        return _failed("watch", ["nothing to watch: this chart declares no symbols"])
    too_long = [name for name in names if len(name.encode()) > WATCH_NAME_MAX_BYTES]
    if too_long:
        raise SimError(f"watch names longer than {WATCH_NAME_MAX_BYTES} bytes: {too_long}")

    force_csv = _force_csv(forces or [])
    script_text = _script_text(script or [], cycles)

    try:
        veristc = veristc_binary if veristc_binary is not None else find_veristc_binary()
        sim = find_sim_binary(sim_binary)
    except FileNotFoundError as exc:
        raise SimError(str(exc)) from exc

    work = Path(tempfile.mkdtemp(prefix="veride_sim_"))
    try:
        source = work / "graph.st"
        image = work / "graph.sasm"
        table = work / "station.plant"
        source.write_text(st_text, encoding="utf-8")
        table.write_text(plant_text, encoding="utf-8")

        compile_result = _run(
            [str(veristc), "-c", str(source), "-o", str(image), "--json"], timeout_s
        )
        diagnostics = parse_ndjson_diagnostics(compile_result.stdout)
        if compile_result.returncode != 0 or not image.is_file():
            return _failed(
                "compile",
                [d.message for d in diagnostics if d.severity == "error"]
                or [compile_result.stderr.strip() or "the compiler rejected the generated text"],
                diagnostics=diagnostics,
            )

        stimulus: list[str] = []
        if force_csv:
            stimulus += ["--force", force_csv]
        if script_text:
            script_path = work / "graph.stim"
            script_path.write_text(script_text, encoding="utf-8")
            stimulus += ["--script", str(script_path)]

        series: dict[str, Series] = {}
        timeline: list[dict] = []
        done: Optional[dict] = None
        errors: list[str] = []

        for chunk in _chunks(names, WATCH_NAMES_PER_RUN):
            command = [
                str(sim), "-q",
                "-n", str(cycles),
                "-t", str(cycle_ms),
                "--watch", ",".join(chunk),
                *stimulus,
                str(image), str(table),
            ]
            completed = _run(command, timeout_s)
            if completed.returncode != 0:
                errors.extend(_refusal_lines(completed, chunk))
                continue
            frames = _frames(completed.stdout)
            if frames["done"] is None:
                errors.append(f"watch stream for {chunk} ended without a done frame")
                continue
            if done is None:
                done = frames["done"]
            for cycle in frames["cycles"]:
                _merge_cycle(timeline, cycle)
                for value in cycle["values"]:
                    row = series.setdefault(
                        value["name"],
                        Series(
                            name=value["name"],
                            addr=value["addr"],
                            type=value["type"],
                            size=value["size"],
                            channel=value["channel"],
                        ),
                    )
                    row.values.append(value["value"])
                    row.raw.append(value["raw"])
                    row.forced.append(bool(value["forced"]))

        if errors:
            return _failed("simulate", errors)
        missing = [name for name in names if name not in series]
        if missing:
            return _failed("simulate", [f"no frame carried: {missing}"])

        return SimRun(
            ok=True,
            payload={
                "ok": True,
                "cycles": cycles,
                "cycle_ms": cycle_ms,
                "runs": len(_chunks(names, WATCH_NAMES_PER_RUN)),
                "done": done,
                "timeline": timeline,
                "symbols": [row.to_dict() for row in series.values()],
            },
        )
    finally:
        for item in sorted(work.glob("*")):
            item.unlink(missing_ok=True)
        work.rmdir()


def _merge_cycle(timeline: list[dict], cycle: dict) -> None:
    """Fold one cycle frame's header into the shared timeline.

    Chunked runs each report the same cycles, so the first run wins and a later
    run that disagrees means the streams were not comparable after all.
    """
    entry = {"cycle": cycle["cycle"], "t_ms": cycle["t_ms"],
             "status": cycle["status"], "violations": cycle["violations"]}
    existing = next((row for row in timeline if row["cycle"] == entry["cycle"]), None)
    if existing is None:
        timeline.append(entry)
    elif existing != entry:
        raise SimError(f"watch runs disagree about cycle {entry['cycle']}: {existing} vs {entry}")
    timeline.sort(key=lambda row: row["cycle"])


def _frames(stdout: str) -> dict:
    cycles: list[dict] = []
    done: Optional[dict] = None
    for line in stdout.splitlines():
        if not line.startswith('{"frame":'):
            continue  # the compiled program's own PRINT output
        frame = json.loads(line)
        if frame.get("frame") == "cycle":
            cycles.append(frame)
        elif frame.get("frame") == "done":
            done = frame
    return {"cycles": cycles, "done": done}


def _refusal_lines(completed: subprocess.CompletedProcess, chunk: list[str]) -> list[str]:
    """`sim` says on stderr why it refused to start; the names say which run.

    Every line is kept: a stimulus refusal prints the offending record first and
    only its last line says the generic "stimulus rejected".
    """
    text = (completed.stderr or completed.stdout or "").strip()
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    reason = " | ".join(lines) if lines else "no reason given"
    return [f"sim refused {chunk} (exit {completed.returncode}): {reason}"]


def _failed(stage: str, errors: list[str], diagnostics: Optional[list[Diagnostic]] = None) -> SimRun:
    payload: dict = {"ok": False, "stage": stage, "errors": errors}
    if diagnostics is not None:
        payload["diagnostics"] = [
            {"severity": d.severity, "kind": d.kind, "message": d.message, "loc": d.loc}
            for d in diagnostics
        ]
    return SimRun(ok=False, payload=payload, errors=errors)


def _force_csv(forces: list[dict]) -> str:
    """The `--force` list: `name=value` pairs, one override per symbol.

    The same name twice is refused here rather than left to the runner, because
    the order the editor's force table yields is not a statement about intent.
    """
    items: list[str] = []
    seen: set[str] = set()
    for row in forces:
        name = _check_stimulus_name(row.get("name", ""))
        if name in seen:
            raise SimError(f"force {name}: given twice, so which value wins is undefined")
        seen.add(name)
        items.append(f"{name}={format_stimulus_value(name, row.get('value'))}")
    if len(items) > FORCE_MAX_TARGETS:
        raise SimError(f"force: {len(items)} symbols exceeds the {FORCE_MAX_TARGETS} the runner holds")
    return ",".join(items)


def _script_text(script: list[dict], cycles: int) -> str:
    """The `.script` body: one `cycle name value` record per line, in cycle order.

    A record past the last simulated cycle can never take effect; refusing it is
    the honest answer, since the alternative is a script that looks like it ran.
    """
    rows: list[tuple[int, str, str]] = []
    for row in script:
        cycle = row.get("cycle")
        if not isinstance(cycle, int) or isinstance(cycle, bool):
            raise SimError(f"script: cycle {cycle!r} is not a whole number")
        if cycle < 1:
            raise SimError(f"script: cycle numbers start at 1, not {cycle}")
        if cycle > cycles:
            raise SimError(f"script: cycle {cycle} is past the {cycles} cycles this run simulates")
        name = _check_stimulus_name(row.get("name", ""))
        rows.append((cycle, name, format_stimulus_value(name, row.get("value"))))
    if len(rows) > FORCE_MAX_RECORDS:
        raise SimError(f"script: {len(rows)} records exceeds the {FORCE_MAX_RECORDS} the runner holds")
    rows.sort(key=lambda row: (row[0], row[1]))
    return "".join(f"{cycle} {name} {value}\n" for cycle, name, value in rows)


def _chunks(names: list[str], size: int) -> list[list[str]]:
    return [names[i : i + size] for i in range(0, len(names), size)]


def _run(command: list[str], timeout_s: int) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            command, capture_output=True, text=True, check=False, timeout=timeout_s
        )
    except subprocess.TimeoutExpired as exc:
        raise SimError(f"{Path(command[0]).name} timed out after {timeout_s}s") from exc
    except OSError as exc:
        raise SimError(f"cannot run {command[0]}: {exc}") from exc
