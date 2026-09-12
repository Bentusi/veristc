#!/usr/bin/env python3
"""Generate the engineering-scale four-channel/two-train ST test model."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ST_PATH = ROOT / "tests/st-examples/nuclear_rps_esfas_full.st"
LAYOUT_PATH = ROOT / "tests/veristc-tests/out/nuclear_rps_esfas_full_layout.h"

CHANNELS = ("a", "b", "c", "d")
INITIATORS = 128
MASK_GROUPS = 16
ACTUATIONS = ("si", "ci", "mfw", "afw")


def threshold(initiator: int) -> int:
    return 100 + initiator % 40


def emit_declarations(out: list[str]) -> None:
    out.extend([
        "PROGRAM NuclearRpsEsfasFull",
        "VAR_INPUT",
        "    reactor_mode : DINT;",
        "    train_a_inhibit : BOOL;",
        "    train_b_inhibit : BOOL;",
        "    train_a_reset : BOOL;",
        "    train_b_reset : BOOL;",
    ])
    for channel in CHANNELS:
        out.append(f"    quality_{channel} : BOOL;")
        out.append(f"    bypass_{channel} : BOOL;")
    for initiator in range(INITIATORS):
        for channel in CHANNELS:
            out.append(f"    raw_{initiator:03d}_{channel} : DINT;")
    out.append("END_VAR")

    out.append("VAR_OUTPUT")
    for train in ("a", "b"):
        for group in range(MASK_GROUPS):
            out.append(f"    mask_{train}_{group:02d} : DINT;")
    for train in ("a", "b"):
        out.append(f"    trip_{train} : BOOL;")
        out.append(f"    scram_{train} : BOOL;")
        out.append(f"    breaker_{train} : BOOL;")
        for actuation in ACTUATIONS:
            out.append(f"    {actuation}_{train} : BOOL;")
        out.append(f"    alarm_{train} : BOOL;")
    for channel in CHANNELS:
        out.append(f"    channel_fault_{channel} : DINT;")
    out.append("END_VAR")

    out.extend([
        "VAR",
        "    cond_a : BOOL;",
        "    cond_b : BOOL;",
        "    cond_c : BOOL;",
        "    cond_d : BOOL;",
        "    input_valid_a : BOOL;",
        "    input_valid_b : BOOL;",
        "    input_valid_c : BOOL;",
        "    input_valid_d : BOOL;",
        "    vote_ok : BOOL;",
        "    diagnosis_count : DINT;",
        "    filter_a : DINT;",
        "    filter_b : DINT;",
        "    filter_c : DINT;",
        "    filter_d : DINT;",
    ])
    for initiator in range(INITIATORS):
        out.append(f"    latch_a_{initiator:03d} : BOOL;")
        out.append(f"    latch_b_{initiator:03d} : BOOL;")
    out.extend([
        "END_VAR",
        "",
    ])


def emit_initialization(out: list[str]) -> None:
    for train in ("a", "b"):
        for group in range(MASK_GROUPS):
            out.append(f"mask_{train}_{group:02d} := 0 + 0;")
    for train in ("a", "b"):
        out.append(f"trip_{train} := 0 > 1;")
        out.append(f"scram_{train} := 0 > 1;")
        out.append(f"breaker_{train} := 0 < 1;")
        for actuation in ACTUATIONS:
            out.append(f"{actuation}_{train} := 0 > 1;")
        out.append(f"alarm_{train} := 0 > 1;")
    for channel in CHANNELS:
        out.append(f"channel_fault_{channel} := 0 + 0;")
    out.append("diagnosis_count := 0 + 0;")
    out.append("")


def emit_channel_processing(out: list[str], initiator: int) -> None:
    limit = threshold(initiator)
    for channel in CHANNELS:
        raw = f"raw_{initiator:03d}_{channel}"
        measured = f"filter_{channel}" if initiator == 0 else raw
        out.append(f"cond_{channel} := LimitHigh({measured}, {limit});")
        out.append(f"cond_{channel} := cond_{channel} AND quality_{channel};")
        out.append(f"cond_{channel} := cond_{channel} AND (NOT bypass_{channel});")
        out.append(
            f"input_valid_{channel} := InputValid({raw}, 0, 1000);"
        )
        out.append(f"cond_{channel} := cond_{channel} AND input_valid_{channel};")
        out.append(f"IF NOT input_valid_{channel} THEN")
        out.append(f"    channel_fault_{channel} := channel_fault_{channel} + 1;")
        out.append("END_IF;")


def emit_voting(out: list[str], initiator: int) -> None:
    out.append("vote_ok := TwoOfFour(cond_a, cond_b, cond_c, cond_d);")

    out.append("IF cond_a <> cond_b THEN")
    out.append("    diagnosis_count := diagnosis_count + 1;")
    out.append("END_IF;")
    out.append("IF cond_c <> cond_d THEN")
    out.append("    diagnosis_count := diagnosis_count + 1;")
    out.append("END_IF;")

    out.append("IF NOT vote_ok THEN")
    out.append("    diagnosis_count := diagnosis_count + 1;")
    out.append("END_IF;")


def emit_train_vote(out: list[str], initiator: int, train: str) -> None:
    group = initiator // 8
    bit = 1 << (initiator % 8)
    actuation = ACTUATIONS[initiator % len(ACTUATIONS)]

    out.append(
        f"latch_{train}_{initiator:03d} := "
        f"RS_Next(vote_ok, train_{train}_reset, latch_{train}_{initiator:03d});"
    )
    out.append(
        f"IF latch_{train}_{initiator:03d} "
        f"AND (NOT train_{train}_inhibit) THEN"
    )
    out.append(f"    mask_{train}_{group:02d} := mask_{train}_{group:02d} + {bit};")
    out.append(f"    trip_{train} := 0 < 1;")
    out.append(f"    scram_{train} := 0 < 1;")
    out.append(f"    breaker_{train} := 0 > 1;")
    out.append(f"    {actuation}_{train} := 0 < 1;")
    out.append(f"    alarm_{train} := 0 < 1;")
    out.append("END_IF;")


def emit_diagnostics(out: list[str], initiator: int) -> None:
    limit = threshold(initiator)
    for channel in CHANNELS:
        raw = f"raw_{initiator:03d}_{channel}"
        out.append(f"IF ({raw} > {limit}) AND (NOT cond_{channel}) THEN")
        out.append(f"    channel_fault_{channel} := channel_fault_{channel} + 1;")
        out.append("END_IF;")

    out.append("IF vote_ok AND train_a_inhibit THEN")
    out.append("    diagnosis_count := diagnosis_count + 1;")
    out.append("END_IF;")
    out.append("IF vote_ok AND train_b_inhibit THEN")
    out.append("    diagnosis_count := diagnosis_count + 1;")
    out.append("END_IF;")


def generate_st() -> str:
    out: list[str] = []
    emit_declarations(out)
    emit_initialization(out)

    for channel in CHANNELS:
        out.append(
            f"filter_{channel} := "
            f"FilterStep(filter_{channel}, raw_000_{channel});"
        )
    out.append("")
    out.append("IF reactor_mode < 0 THEN")
    out.append("    diagnosis_count := diagnosis_count + 1;")
    out.append("END_IF;")
    out.append("")

    for initiator in range(INITIATORS):
        emit_channel_processing(out, initiator)
        emit_voting(out, initiator)
        emit_train_vote(out, initiator, "a")
        emit_train_vote(out, initiator, "b")
        emit_diagnostics(out, initiator)
        out.append("")

    out.append("END_PROGRAM")
    out.append("")
    out.extend([
        "FUNCTION LimitHigh : BOOL",
        "VAR_INPUT",
        "    value : DINT;",
        "    high : DINT;",
        "END_VAR",
        "LimitHigh := value > high;",
        "END_FUNCTION",
        "",
        "FUNCTION InputValid : BOOL",
        "VAR_INPUT",
        "    value : DINT;",
        "    low : DINT;",
        "    high : DINT;",
        "END_VAR",
        "InputValid := (value >= low) AND (value <= high);",
        "END_FUNCTION",
        "",
        "FUNCTION OneOfTwo : BOOL",
        "VAR_INPUT",
        "    input_a : BOOL;",
        "    input_b : BOOL;",
        "END_VAR",
        "OneOfTwo := input_a OR input_b;",
        "END_FUNCTION",
        "",
        "FUNCTION TwoOfFour : BOOL",
        "VAR_INPUT",
        "    input_a : BOOL;",
        "    input_b : BOOL;",
        "    input_c : BOOL;",
        "    input_d : BOOL;",
        "END_VAR",
        "TwoOfFour := OneOfTwo(OneOfTwo(OneOfTwo(input_a AND input_b, input_c AND input_d), OneOfTwo(input_a AND input_c, input_b AND input_d)), OneOfTwo(input_a AND input_d, input_b AND input_c));",
        "END_FUNCTION",
        "",
        "FUNCTION RS_Next : BOOL",
        "VAR_INPUT",
        "    set_input : BOOL;",
        "    reset_input : BOOL;",
        "    q_previous : BOOL;",
        "END_VAR",
        "RS_Next := (set_input OR q_previous) AND (NOT reset_input);",
        "END_FUNCTION",
        "",
        "FUNCTION FilterStep : DINT",
        "VAR_INPUT",
        "    previous : DINT;",
        "    input_value : DINT;",
        "END_VAR",
        "FilterStep := previous + ((input_value - previous) / 2);",
        "END_FUNCTION",
        "",
    ])
    return "\n".join(out)


def generate_layout() -> str:
    input_count = 5 + 2 * len(CHANNELS) + INITIATORS * len(CHANNELS)
    output_count = 2 * MASK_GROUPS + 2 * (4 + len(ACTUATIONS)) + len(CHANNELS)
    work_count = 10 + len(CHANNELS) + 2 * INITIATORS
    local_count = input_count + output_count + work_count

    lines = [
        "/* Generated by gen_nuclear_rps_esfas_full.py. */",
        "#ifndef NUCLEAR_RPS_ESFAS_FULL_LAYOUT_H",
        "#define NUCLEAR_RPS_ESFAS_FULL_LAYOUT_H",
        "",
        f"#define NFULL_INITIATORS {INITIATORS}",
        f"#define NFULL_MASK_GROUPS {MASK_GROUPS}",
        f"#define NFULL_LOCAL_COUNT {local_count}",
        f"#define NFULL_INPUT_COUNT {input_count}",
        f"#define NFULL_OUTPUT_COUNT {output_count}",
        "",
        "#define NFULL_IN_TRAIN_A_RESET 3",
        "#define NFULL_IN_TRAIN_B_RESET 4",
        "#define NFULL_IN_QUALITY_A 5",
        "#define NFULL_IN_BYPASS_A 6",
        "#define NFULL_IN_QUALITY_B 7",
        "#define NFULL_IN_BYPASS_B 8",
        "#define NFULL_IN_QUALITY_C 9",
        "#define NFULL_IN_BYPASS_C 10",
        "#define NFULL_IN_QUALITY_D 11",
        "#define NFULL_IN_BYPASS_D 12",
        "#define NFULL_IN_RAW_BASE 13",
        "#define NFULL_RAW_INDEX(initiator, channel) \\",
        "    (NFULL_IN_RAW_BASE + ((initiator) * 4) + (channel))",
        "",
        "#define NFULL_OUT_MASK_A_BASE NFULL_INPUT_COUNT",
        "#define NFULL_OUT_MASK_B_BASE (NFULL_OUT_MASK_A_BASE + NFULL_MASK_GROUPS)",
        "#define NFULL_OUT_TRIP_A (NFULL_OUT_MASK_B_BASE + NFULL_MASK_GROUPS)",
        "#define NFULL_OUT_SCRAM_A (NFULL_OUT_TRIP_A + 1)",
        "#define NFULL_OUT_BREAKER_A (NFULL_OUT_TRIP_A + 2)",
        "#define NFULL_OUT_SI_A (NFULL_OUT_TRIP_A + 3)",
        "#define NFULL_OUT_CI_A (NFULL_OUT_TRIP_A + 4)",
        "#define NFULL_OUT_MFW_A (NFULL_OUT_TRIP_A + 5)",
        "#define NFULL_OUT_AFW_A (NFULL_OUT_TRIP_A + 6)",
        "#define NFULL_OUT_ALARM_A (NFULL_OUT_TRIP_A + 7)",
        "#define NFULL_OUT_TRIP_B (NFULL_OUT_TRIP_A + 8)",
        "#define NFULL_OUT_SCRAM_B (NFULL_OUT_TRIP_B + 1)",
        "#define NFULL_OUT_BREAKER_B (NFULL_OUT_TRIP_B + 2)",
        "#define NFULL_OUT_SI_B (NFULL_OUT_TRIP_B + 3)",
        "#define NFULL_OUT_CI_B (NFULL_OUT_TRIP_B + 4)",
        "#define NFULL_OUT_MFW_B (NFULL_OUT_TRIP_B + 5)",
        "#define NFULL_OUT_AFW_B (NFULL_OUT_TRIP_B + 6)",
        "#define NFULL_OUT_ALARM_B (NFULL_OUT_TRIP_B + 7)",
        "#define NFULL_OUT_FAULT_A (NFULL_OUT_TRIP_B + 8)",
        "#define NFULL_OUT_FAULT_B (NFULL_OUT_FAULT_A + 1)",
        "#define NFULL_OUT_FAULT_C (NFULL_OUT_FAULT_A + 2)",
        "#define NFULL_OUT_FAULT_D (NFULL_OUT_FAULT_A + 3)",
        "",
        "#define NFULL_TRIP_THRESHOLD(initiator) (100 + ((initiator) % 40))",
        "#define NFULL_MASK_GROUP(initiator) ((initiator) / 8)",
        "#define NFULL_MASK_BIT(initiator) (1 << ((initiator) % 8))",
        "",
        "#endif",
        "",
    ]
    return "\n".join(lines)


def main() -> None:
    ST_PATH.write_text(generate_st(), encoding="ascii")
    LAYOUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    LAYOUT_PATH.write_text(generate_layout(), encoding="ascii")
    print(f"generated: {ST_PATH}")
    print(f"generated: {LAYOUT_PATH}")


if __name__ == "__main__":
    main()
