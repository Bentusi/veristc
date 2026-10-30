"""Compiler analysis hand-off: `.sasm` section reader, measured numbers, and the API gate.

These tests run the real compiler, so they skip when `build/bin/veristc` is absent.
"""

import struct

import pytest
from fastapi.testclient import TestClient

import veri_ide.backend.graph.service as graph_service
from veri_ide.backend.build.analysis import AnalysisError, run_analysis
from veri_ide.backend.build.sasm_reader import (
    CRC_BYTES,
    HEADER_BYTES,
    SECTION_HEADER_BYTES,
    SasmError,
    read,
    read_file,
)
from veri_ide.backend.build.service import find_veristc_binary

SMALL_ST = """\
VAR_GLOBAL
    counter : DINT;
    setpoint : REAL;
END_VAR
PROGRAM MAIN
    counter := counter + 1;
    setpoint := 1.5;
END_PROGRAM
"""

REJECTED_ST = """\
PROGRAM MAIN
    missing := 1;
END_PROGRAM
"""


@pytest.fixture(scope="module")
def veristc():
    try:
        return find_veristc_binary()
    except FileNotFoundError:
        pytest.skip("veristc binary not found")


@pytest.fixture(scope="module")
def small_image(tmp_path_factory, veristc):
    """One real compiled image, used by both the reader and the analysis tests."""
    import subprocess

    work = tmp_path_factory.mktemp("analysis")
    source = work / "small.st"
    image = work / "small.sasm"
    source.write_text(SMALL_ST, encoding="utf-8")
    subprocess.run(
        [str(veristc), "-c", str(source), "-o", str(image)],
        check=True,
        capture_output=True,
        text=True,
    )
    return image


def test_reader_reports_every_declared_section(small_image):
    image = read_file(small_image)

    assert {"TYPE", "FUNC", "MEM", "IOMAP", "CODE", "SAFE"} <= set(image.sections)
    assert image.safety_level == "SIL3"
    assert image.cycle_limit == 1_000_000
    assert image.memory_total > 0
    assert image.code_bytes > 0
    assert image.file_bytes == small_image.stat().st_size


def test_global_segment_is_where_the_compiler_declares_it(small_image):
    image = read_file(small_image)
    globals_ = [segment for segment in image.segments if segment.kind == "GLOBAL"]

    assert globals_, "a program with variables must declare a GLOBAL segment"
    assert all(segment.start >= 4096 for segment in globals_)
    assert image.segment_bytes("GLOBAL") == sum(segment.size for segment in globals_)


def test_wcet_is_read_once_even_though_the_image_carries_two_copies(small_image):
    image = read_file(small_image)

    assert image.wcet, "the WCET section must be present"
    assert all(row.cycles > 0 and row.ns > 0 for row in image.wcet)
    # Section 5 repeats the same table at its tail; section 6 wins, so the total
    # is one row per function and never doubled.
    assert len({row.func_idx for row in image.wcet}) == len(image.wcet)


def test_debug_section_names_resolve(small_image):
    image = read_file(small_image)
    by_name = {symbol["name"]: symbol for symbol in image.symbols}

    assert {"counter", "setpoint", "__veristc_cycle_counter"} <= set(by_name), (
        "the global section is what the monitor addresses, so it must name them"
    )
    assert by_name["counter"]["address"] == by_name["setpoint"]["address"] - 4
    assert all(symbol["size"] == 4 for symbol in image.symbols)


def test_reader_rejects_a_truncated_section(small_image):
    data = small_image.read_bytes()

    # Drop the CRC: the last section then declares more bytes than the body holds.
    with pytest.raises(SasmError):
        read(data[:-4])

    # Cut a section body while leaving its declared length in place.
    offset = HEADER_BYTES
    while offset + SECTION_HEADER_BYTES <= len(data) - CRC_BYTES:
        length = struct.unpack_from("<I", data, offset + 1)[0]
        if data[offset] == 2:
            body = offset + SECTION_HEADER_BYTES
            with pytest.raises(SasmError):
                read(data[:body] + data[body + length :])
            return
        offset += SECTION_HEADER_BYTES + length
    pytest.fail("no memory section in the fixture image")


def test_reader_rejects_a_bad_magic():
    with pytest.raises(SasmError, match="magic"):
        read(b"XXXX" + b"\x01\x00" + b"\x00" * 20)


def test_analysis_measures_wcet_memory_and_sync_region(small_image, veristc):
    result = run_analysis(SMALL_ST, station={"station_id": "ST1", "cycle_ms": 100},
                          veristc_path=veristc)
    payload = result.payload

    assert result.ok and payload["ok"]
    assert payload["analysis"]["recursive_calls"] is False
    assert payload["analysis"]["loops_bounded"] is True
    assert payload["wcet"]["total_ns"] > 0
    assert payload["wcet"]["fits_cycle"] is True
    assert payload["wcet"]["station_cycle_ms"] == 100
    assert payload["wcet"]["used_percent"] < 1.0

    assert payload["memory"]["symbols"] >= 2
    assert payload["memory"]["by_kind"]["GLOBAL"]["bytes"] > 0

    sync = payload["sync_region"]
    assert sync["mandatory_page_count"] >= 1
    assert sync["bytes_per_cycle"] == sync["mandatory_page_count"] * sync["page_size"]
    assert sync["within_page_limit"] is True


def test_analysis_compiler_estimate_and_image_agree(small_image, veristc):
    payload = run_analysis(SMALL_ST, veristc_path=veristc).payload

    # `veristc -a` and section 6 measure the same program; they must not disagree.
    assert payload["wcet"]["total_cycles"] == payload["analysis"]["estimated_wcet"]


def test_analysis_surfaces_a_rejection_without_inventing_numbers(veristc):
    result = run_analysis(REJECTED_ST, veristc_path=veristc)

    assert not result.ok
    assert result.payload["stage"] == "analysis"
    assert "wcet" not in result.payload, "a rejected program has nothing to measure"
    assert result.diagnostics and result.diagnostics[0].message


def test_analysis_raises_when_the_binary_is_missing(tmp_path):
    with pytest.raises(AnalysisError):
        run_analysis(SMALL_ST, veristc_path=tmp_path / "nope-not-here")


# ---------- API gate ----------


@pytest.fixture
def client():
    from veri_ide.api.server import app

    graph_service._PROJECT = None
    yield TestClient(app)
    graph_service._PROJECT = None


def test_analysis_refuses_while_the_checker_reports_errors(client):
    looped = {
        "version": "1.1",
        "type": "FC",
        "name": "MAIN",
        "page": {"id": "PAGE1", "label": "页 1", "index": 0, "sheet": "A3"},
        "interface": {"input": [], "output": [], "in_out": []},
        "constants": [],
        "blocks": [{"id": "b1", "type": "LIMITER", "position": {"x": 40, "y": 40}}],
        "connections": [{"from": {"block": "b1", "port": "OUT"},
                         "to": {"block": "b1", "port": "IN"}}],
    }
    assert client.put("/graph/pages/PAGE1", json=looped).status_code == 200

    payload = client.post("/graph/analysis", json={"station": None}).json()

    assert payload["ok"] is False
    assert payload["stage"] == "checker"
    assert payload["errors"], "the refusal must carry the findings that block it"


def test_analysis_measures_a_bound_and_wired_chart(client):
    chart = {
        "version": "1.1",
        "type": "FC",
        "name": "MAIN",
        "page": {"id": "PAGE1", "label": "页 1", "index": 0, "sheet": "A3"},
        "interface": {
            "input": [
                {"name": "IN", "type": "REAL", "scope": "external",
                 "bind": {"station": "ST1", "variable": "PV"},
                 "position": {"x": 64, "y": 120}}
            ],
            "output": [
                {"name": "OUT", "type": "REAL", "scope": "external",
                 "bind": {"station": "ST1", "variable": "OUT"},
                 "position": {"x": 1200, "y": 120}}
            ],
            "in_out": [],
        },
        "constants": [],
        "blocks": [{"id": "lim1", "type": "LIMITER", "position": {"x": 400, "y": 120}}],
        "connections": [
            {"from": {"block": "__interface__", "port": "IN"},
             "to": {"block": "lim1", "port": "IN"}},
            {"from": {"block": "lim1", "port": "OUT"},
             "to": {"block": "__interface__", "port": "OUT"}},
        ],
    }
    assert client.put("/graph/pages/PAGE1", json=chart).status_code == 200
    assert client.post("/graph/check", json={"station": None}).json()["ok"] is True

    payload = client.post("/graph/analysis", json={"station": None}).json()

    assert payload["ok"] is True, payload
    assert payload["station"]["station_id"] == "ST1"
    assert payload["station"]["cycle_ms"] == payload["wcet"]["station_cycle_ms"]
    assert payload["memory"]["io_channels"] > 0, "the station's IOMAP must reach the image"
    assert payload["sync_region"]["bytes_per_cycle"] > 0
