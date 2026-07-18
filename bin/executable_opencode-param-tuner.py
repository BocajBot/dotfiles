#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_CONFIG = Path.home() / ".config/llama-swap/config.yaml"
DEFAULT_OUT_ROOT = Path.home() / "opencode-baselines" / "param-tuning"
DEFAULT_BENCHMARK = Path.home() / "bin/opencode-baseline-newcfg.sh"


@dataclass(frozen=True)
class Variant:
    alias: str
    label: str
    changes: tuple[tuple[str, Any], ...]


def sanitize_label(s: str) -> str:
    s = str(s)
    s = s.replace("/", "-")
    s = s.replace(",", "-")
    s = s.replace(" ", "")
    s = s.replace(".", "p")
    return re.sub(r"[^A-Za-z0-9_.=-]+", "-", s)


def short_label(param: str, value: Any) -> str:
    if param == "reasoning_budget":
        return f"rb{value}"
    if param == "reasoning_off":
        return "reasoning-off"
    if param == "ubatch_size":
        return f"ub{value}"
    if param == "batch_size":
        return f"b{value}"
    if param == "ctx_size":
        return f"ctx{value}"
    if param == "cache_ram":
        return f"cram{value}"
    if param == "cache_reuse":
        return f"creuse{value}"
    if param == "kv":
        k, v = value
        return f"kv-{sanitize_label(k)}-{sanitize_label(v)}"
    if param == "sampling":
        temp, top_p, min_p = value
        return f"temp{sanitize_label(temp)}-top{sanitize_label(top_p)}-min{sanitize_label(min_p)}"
    if param == "spec_draft_n_max":
        return f"draftn{value}"
    if param == "tensor_split":
        return f"ts{sanitize_label(value)}"
    if param == "split_mode":
        return f"sm{sanitize_label(value)}"
    if param == "device":
        return f"dev{sanitize_label(value)}"
    if param == "ngl":
        return f"ngl{sanitize_label(value)}"
    if param == "fit":
        return f"fit{sanitize_label(value)}"
    return f"{sanitize_label(param)}-{sanitize_label(value)}"


def read_text(path: Path) -> str:
    try:
        return path.read_text()
    except FileNotFoundError:
        raise SystemExit(f"File not found: {path}")


def model_block_pattern(model: str) -> str:
    return rf"(?ms)^  {re.escape(model)}:\n.*?(?=\n  [A-Za-z0-9_.-]+:\n|\Z)"


def extract_model_block(config_text: str, model: str) -> str:
    m = re.search(model_block_pattern(model), config_text)
    if not m:
        raise SystemExit(f"Could not find model block: {model}")
    return m.group(0).rstrip() + "\n"


def set_model_key(block: str, new_key: str) -> str:
    return re.sub(r"(?m)^  [A-Za-z0-9_.-]+:\s*$", f"  {new_key}:", block, count=1)


def set_name(block: str, name: str) -> str:
    if re.search(r'(?m)^    name:\s*".*"\s*$', block):
        return re.sub(r'(?m)^    name:\s*".*"\s*$', f'    name: "{name}"', block, count=1)
    return block.replace("\n    cmd: |", f'\n    name: "{name}"\n    cmd: |', 1)


def has_arg(block: str, arg: str) -> bool:
    return bool(re.search(rf"(?m)^      {re.escape(arg)}(?:\s+.*)?$", block))


def remove_arg(block: str, arg: str) -> str:
    # Remove only the exact argument line.
    # Important: --reasoning must not partially match --reasoning-budget.
    return re.sub(
        rf"(?m)^      {re.escape(arg)}(?:\s+.*)?(?:\n|$)",
        "",
        block,
    )


def insert_arg_after_alias(block: str, arg: str, value: str | None = None) -> str:
    line = f"      {arg}" if value is None else f"      {arg} {value}"
    alias_line = re.search(r"(?m)^      --alias\s+.*$", block)
    if alias_line:
        end = alias_line.end()
        return block[:end] + "\n" + line + block[end:]
    cmd_line = re.search(r"(?m)^    cmd:\s*\|.*$", block)
    if cmd_line:
        end = cmd_line.end()
        return block[:end] + "\n" + line + block[end:]
    raise SystemExit("Could not find insertion point in model block.")


def set_arg(block: str, arg: str, value: str | int | float) -> str:
    value = str(value)
    pat = rf"(?m)^      {re.escape(arg)}\s+.*$"
    if re.search(pat, block):
        return re.sub(pat, f"      {arg} {value}", block, count=1)
    return insert_arg_after_alias(block, arg, value)


def set_flag(block: str, arg: str) -> str:
    pat = rf"(?m)^      {re.escape(arg)}(?:\s+.*)?$"
    if re.search(pat, block):
        return re.sub(pat, f"      {arg}", block, count=1)
    return insert_arg_after_alias(block, arg, None)


def set_alias(block: str, alias: str) -> str:
    return set_arg(block, "--alias", alias)


def apply_change(block: str, param: str, value: Any) -> str:
    if param == "reasoning_budget":
        block = remove_arg(block, "--reasoning")
        return set_arg(block, "--reasoning-budget", value)

    if param == "reasoning_off":
        block = remove_arg(block, "--reasoning-budget")
        return set_arg(block, "--reasoning", "off")

    if param == "ubatch_size":
        return set_arg(block, "--ubatch-size", value)

    if param == "batch_size":
        return set_arg(block, "--batch-size", value)

    if param == "ctx_size":
        return set_arg(block, "--ctx-size", value)

    if param == "cache_ram":
        return set_arg(block, "--cache-ram", value)

    if param == "cache_reuse":
        return set_arg(block, "--cache-reuse", value)

    if param == "kv":
        k, v = value
        block = set_arg(block, "--cache-type-k", k)
        block = set_arg(block, "--cache-type-v", v)
        return block

    if param == "sampling":
        temp, top_p, min_p = value
        block = set_arg(block, "--temp", temp)
        block = set_arg(block, "--top-p", top_p)
        block = set_arg(block, "--min-p", min_p)
        return block

    if param == "spec_draft_n_max":
        return set_arg(block, "--spec-draft-n-max", value)

    if param == "tensor_split":
        return set_arg(block, "--tensor-split", value)

    if param == "split_mode":
        return set_arg(block, "--split-mode", value)

    if param == "device":
        return set_arg(block, "--device", value)

    if param == "ngl":
        return set_arg(block, "-ngl", value)

    if param == "fit":
        return set_arg(block, "-fit", value)

    raise SystemExit(f"Unknown parameter: {param}")


def clone_variant(base_block: str, alias: str, label: str, changes: tuple[tuple[str, Any], ...]) -> str:
    block = set_model_key(base_block, alias)
    block = set_name(block, f"{alias} [{label}]")
    block = set_alias(block, alias)

    for param, value in changes:
        block = apply_change(block, param, value)

    return block.rstrip() + "\n"


def default_search_space() -> dict[str, list[Any]]:
    return {
        "reasoning_budget": [32, 64, 128, 256],
        "ubatch_size": [128, 192, 256, 384, 512],
        "batch_size": [1024, 1536, 2048],
        "cache_ram": [0, 2048, 4096, 8192],
        "cache_reuse": [128, 256, 512],
        "kv": [("q8_0", "q8_0"), ("f16", "f16"), ("q4_0", "q8_0")],
        "sampling": [
            (0.05, 0.75, 0.0),
            (0.10, 0.85, 0.0),
            (0.20, 0.90, 0.0),
            (0.30, 0.95, 0.0),
        ],
    }


def qwable_search_space() -> dict[str, list[Any]]:
    # Conservative first pass for Qwable.
    # This intentionally avoids tensor-split/device/split-mode initially because those can
    # change memory behavior drastically and make results harder to interpret.
    return {
        "reasoning_budget": [32, 64, 128, 256],
        "ubatch_size": [128, 192, 256, 384, 512],
        "batch_size": [1024, 1536, 2048],
        "cache_ram": [0, 2048, 4096, 8192],
        "cache_reuse": [128, 256, 512],
        "kv": [("q8_0", "q8_0"), ("f16", "f16")],
        "sampling": [
            (0.05, 0.75, 0.0),
            (0.10, 0.85, 0.0),
            (0.20, 0.90, 0.0),
        ],
    }


def build_variants(base_model: str, mode: str, space: dict[str, list[Any]]) -> list[Variant]:
    variants: list[Variant] = [
        Variant(
            alias=f"{base_model}__base",
            label="base",
            changes=tuple(),
        )
    ]

    if mode == "oaat":
        for param, values in space.items():
            for value in values:
                label = short_label(param, value)
                alias = f"{base_model}__{label}"
                variants.append(Variant(alias=alias, label=label, changes=((param, value),)))
        return variants

    if mode == "core-pairs":
        # Small interaction test. These are the combinations most likely to interact.
        pairs = [
            ("reasoning_budget", "ubatch_size"),
            ("cache_ram", "cache_reuse"),
            ("kv", "cache_ram"),
            ("sampling", "reasoning_budget"),
        ]

        for left, right in pairs:
            for lv in space[left]:
                for rv in space[right]:
                    llabel = short_label(left, lv)
                    rlabel = short_label(right, rv)
                    alias = f"{base_model}__{llabel}__{rlabel}"
                    variants.append(
                        Variant(
                            alias=alias,
                            label=f"{llabel}+{rlabel}",
                            changes=((left, lv), (right, rv)),
                        )
                    )
        return variants

    if mode == "focused":
        # Smaller practical set for first pass.
        focused_changes = [
            (("reasoning_budget", 32),),
            (("reasoning_budget", 64),),
            (("reasoning_budget", 128),),
            (("reasoning_budget", 256),),

            (("ubatch_size", 128),),
            (("ubatch_size", 256),),
            (("ubatch_size", 512),),

            (("cache_ram", 0),),
            (("cache_ram", 4096),),
            (("cache_ram", 8192),),

            (("kv", ("q8_0", "q8_0")),),
            (("kv", ("f16", "f16")),),

            (("sampling", (0.05, 0.75, 0.0)),),
            (("sampling", (0.10, 0.85, 0.0)),),
            (("sampling", (0.20, 0.90, 0.0)),),

            (("reasoning_budget", 64), ("ubatch_size", 256)),
            (("reasoning_budget", 64), ("ubatch_size", 512)),
            (("reasoning_budget", 128), ("ubatch_size", 256)),
            (("reasoning_budget", 128), ("ubatch_size", 512)),

            (("kv", ("q8_0", "q8_0")), ("cache_ram", 4096)),
            (("kv", ("q8_0", "q8_0")), ("cache_ram", 8192)),
            (("kv", ("f16", "f16")), ("cache_ram", 0)),
        ]

        for changes in focused_changes:
            labels = [short_label(p, v) for p, v in changes]
            alias = f"{base_model}__{'__'.join(labels)}"
            variants.append(
                Variant(
                    alias=alias,
                    label="+".join(labels),
                    changes=tuple(changes),
                )
            )
        return variants

    if mode == "qwable-stage2":
        # Stage 2 Qwable optimization:
        # - confirm q8 KV + cache-ram winners from Stage 1
        # - test higher ubatch values above 512
        # - test whether high ubatch helps or hurts the q8/cache candidate
        stage2_changes = [
            # Controls / confirmation
            tuple(),
            (("kv", ("q8_0", "q8_0")),),
            (("kv", ("q8_0", "q8_0")), ("cache_ram", 4096)),
            (("kv", ("q8_0", "q8_0")), ("cache_ram", 8192)),
            (("cache_ram", 8192),),

            # ubatch alone
            (("ubatch_size", 512),),
            (("ubatch_size", 768),),
            (("ubatch_size", 1024),),
            (("ubatch_size", 1536),),
            (("ubatch_size", 2048),),

            # current best candidate + ubatch
            (("kv", ("q8_0", "q8_0")), ("cache_ram", 8192), ("ubatch_size", 512)),
            (("kv", ("q8_0", "q8_0")), ("cache_ram", 8192), ("ubatch_size", 768)),
            (("kv", ("q8_0", "q8_0")), ("cache_ram", 8192), ("ubatch_size", 1024)),
            (("kv", ("q8_0", "q8_0")), ("cache_ram", 8192), ("ubatch_size", 1536)),
            (("kv", ("q8_0", "q8_0")), ("cache_ram", 8192), ("ubatch_size", 2048)),

            # lower-cache q8 candidate + selected ubatch checks
            (("kv", ("q8_0", "q8_0")), ("cache_ram", 4096), ("ubatch_size", 512)),
            (("kv", ("q8_0", "q8_0")), ("cache_ram", 4096), ("ubatch_size", 1024)),
        ]

        # The generic variant builder already added <base_model>__base.
        # Start with existing aliases so qwable-stage2 does not duplicate base.
        seen = {v.alias for v in variants}
        for changes in stage2_changes:
            if not changes:
                alias = f"{base_model}__base"
                label = "base"
            else:
                labels = [short_label(p, v) for p, v in changes]
                alias = f"{base_model}__{'__'.join(labels)}"
                label = "+".join(labels)

            if alias in seen:
                continue
            seen.add(alias)

            variants.append(
                Variant(
                    alias=alias,
                    label=label,
                    changes=tuple(changes),
                )
            )

        return variants


    raise SystemExit(f"Unknown mode: {mode}")


def generate(args: argparse.Namespace) -> None:
    source_config = Path(args.config).expanduser()
    out_root = Path(args.out_root).expanduser()
    stamp = time.strftime("%Y%m%d-%H%M%S")
    out_dir = out_root / f"{args.model}-{args.mode}-{stamp}"
    out_dir.mkdir(parents=True, exist_ok=True)

    config_text = read_text(source_config)
    base_block = extract_model_block(config_text, args.model)

    if args.space == "qwable":
        space = qwable_search_space()
    else:
        space = default_search_space()

    variants = build_variants(args.model, args.mode, space)

    variant_blocks = []
    for variant in variants:
        variant_blocks.append(
            clone_variant(
                base_block=base_block,
                alias=variant.alias,
                label=variant.label,
                changes=variant.changes,
            )
        )

    out_config = out_dir / "llama-swap.tuning.yaml"
    manifest = out_dir / "variant-manifest.tsv"
    aliases_file = out_dir / "models-only.txt"

    generated_section = "\n# ===== generated parameter tuning variants =====\n" + "\n".join(variant_blocks).rstrip() + "\n"

    # Insert generated aliases immediately after the base model block.
    # This keeps variants inside the same `models:` mapping instead of appending
    # indented model keys after unrelated top-level config keys.
    base_match = re.search(model_block_pattern(args.model), config_text)
    if not base_match:
        raise SystemExit(f"Could not re-find model block for insertion: {args.model}")

    out_config.write_text(
        config_text[:base_match.end()].rstrip()
        + "\n"
        + generated_section
        + config_text[base_match.end():].lstrip("\n")
    )

    with manifest.open("w", newline="") as f:
        writer = csv.writer(f, delimiter="\t")
        writer.writerow(["alias", "base_model", "label", "changes_json"])
        for variant in variants:
            writer.writerow([
                variant.alias,
                args.model,
                variant.label,
                json.dumps(list(variant.changes), sort_keys=True),
            ])

    aliases_file.write_text(" ".join(v.alias for v in variants) + "\n")

    print(f"Output dir:     {out_dir}")
    print(f"Tuning config:  {out_config}")
    print(f"Manifest:       {manifest}")
    print(f"MODELS_ONLY:    {aliases_file}")
    print()
    print("Start llama-swap with:")
    print(f"  llama-swap --config {out_config} --listen 127.0.0.1:9292")
    print()
    print("Run your existing benchmark with:")
    print(f"  MODELS_ONLY=\"$(cat {aliases_file})\" {DEFAULT_BENCHMARK}")
    print()
    print("Then analyze with:")
    print(f"  {Path(sys.argv[0]).expanduser()} analyze --tune-dir {out_dir} --run-dir <NEWCFG_RUN_DIR>")


def as_float(value: str) -> float | None:
    try:
        return float(value)
    except Exception:
        return None


def get_col(row: dict[str, str], names: list[str]) -> str:
    for name in names:
        if name in row and row[name] not in ("", None):
            return row[name]
    return ""


def load_tsv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def analyze(args: argparse.Namespace) -> None:
    tune_dir = Path(args.tune_dir).expanduser()
    run_dir = Path(args.run_dir).expanduser()

    manifest_path = tune_dir / "variant-manifest.tsv"
    summary_path = run_dir / "summary-newcfg.tsv"

    if not manifest_path.exists():
        raise SystemExit(f"Missing manifest: {manifest_path}")
    if not summary_path.exists():
        raise SystemExit(f"Missing summary: {summary_path}")

    manifest = load_tsv(manifest_path)
    summary = load_tsv(summary_path)

    aliases = [r["alias"] for r in manifest]
    base_alias = aliases[0]

    rows_by_alias: dict[str, list[dict[str, str]]] = {a: [] for a in aliases}
    for row in summary:
        model = row.get("model", "")
        if model in rows_by_alias:
            rows_by_alias[model].append(row)

    def summarize(alias: str) -> dict[str, Any]:
        rows = rows_by_alias.get(alias, [])
        elapsed = [as_float(r.get("elapsed_sec", "")) for r in rows]
        elapsed = [x for x in elapsed if x is not None]

        exit_failures = sum(1 for r in rows if r.get("exit_code") not in ("0", 0))
        unsupported = sum(1 for r in rows if r.get("unsupported_command") == "yes")

        command_rows = [
            r for r in rows
            if r.get("prompt") in {
                "02_command_neutral",
                "03_command_evidence",
                "04_command_local_only",
            }
        ]

        proof_required_rows = [
            r for r in rows
            if r.get("prompt") in {
                "03_command_evidence",
                "04_command_local_only",
            }
        ]

        exact_or_alias = sum(
            1 for r in command_rows
            if r.get("exact_build_chrome") == "yes" or r.get("valid_build_alias") == "yes"
        )

        proof = sum(
            1 for r in proof_required_rows
            if r.get("has_proof_path") == "yes"
        )

        return {
            "alias": alias,
            "runs": len(rows),
            "total_sec": round(sum(elapsed), 3) if elapsed else "",
            "avg_sec": round(sum(elapsed) / len(elapsed), 3) if elapsed else "",
            "exit_failures": exit_failures,
            "unsupported": unsupported,
            "command_correct": exact_or_alias,
            "command_proof": proof,
        }

    summaries = {alias: summarize(alias) for alias in aliases}
    base = summaries[base_alias]

    def score(s: dict[str, Any]) -> float:
        avg = s["avg_sec"]
        if avg == "":
            return 999999.0

        base_avg = base["avg_sec"] if base["avg_sec"] != "" else avg
        latency_ratio = float(avg) / float(base_avg)

        missing_correct = max(0, 3 - int(s["command_correct"]))
        # Proof is only required for 03_command_evidence and 04_command_local_only.
        missing_proof = max(0, 2 - int(s["command_proof"]))

        return (
            latency_ratio
            + int(s["exit_failures"]) * 10
            + int(s["unsupported"]) * 3
            + missing_correct * 4
            + missing_proof * 1
        )

    for alias, s in summaries.items():
        s["score"] = round(score(s), 4)

        if s["avg_sec"] != "" and base["avg_sec"] != "":
            delta = float(s["avg_sec"]) - float(base["avg_sec"])
            pct = (delta / float(base["avg_sec"])) * 100
            s["avg_delta_sec"] = round(delta, 3)
            s["avg_delta_pct"] = round(pct, 2)
        else:
            s["avg_delta_sec"] = ""
            s["avg_delta_pct"] = ""

    scores_path = tune_dir / "variant-scores.tsv"
    notes_path = tune_dir / "tuning-notes.md"

    with scores_path.open("w", newline="") as f:
        fields = [
            "alias",
            "runs",
            "total_sec",
            "avg_sec",
            "avg_delta_sec",
            "avg_delta_pct",
            "exit_failures",
            "unsupported",
            "command_correct",
            "command_proof",
            "score",
        ]
        writer = csv.DictWriter(f, delimiter="\t", fieldnames=fields)
        writer.writeheader()
        for alias in sorted(aliases, key=lambda a: summaries[a]["score"]):
            writer.writerow({field: summaries[alias].get(field, "") for field in fields})

    best_alias = min(aliases, key=lambda a: summaries[a]["score"])

    lines = []
    lines.append("# Parameter tuning notes")
    lines.append("")
    lines.append(f"Run dir: `{run_dir}`")
    lines.append(f"Tune dir: `{tune_dir}`")
    lines.append("")
    lines.append(f"Base alias: `{base_alias}`")
    lines.append(f"Best current alias by score: `{best_alias}`")
    lines.append("")
    lines.append("Lower score is better. Score penalizes latency, exit failures, unsupported commands, missing command correctness, and missing proof paths.")
    lines.append("")
    lines.append("## Top variants")
    lines.append("")
    lines.append("| Rank | Alias | Avg sec | Delta % | Unsupported | Correct command rows | Proof rows | Score |")
    lines.append("|---:|---|---:|---:|---:|---:|---:|---:|")

    for rank, alias in enumerate(sorted(aliases, key=lambda a: summaries[a]["score"])[:15], 1):
        s = summaries[alias]
        lines.append(
            f"| {rank} | `{alias}` | {s['avg_sec']} | {s['avg_delta_pct']} | "
            f"{s['unsupported']} | {s['command_correct']}/3 | {s['command_proof']}/2 | {s['score']} |"
        )

    lines.append("")
    lines.append("## Notes")
    lines.append("")

    for alias in sorted(aliases, key=lambda a: summaries[a]["score"]):
        s = summaries[alias]
        if alias == base_alias:
            continue

        note_bits = []

        if s["avg_delta_pct"] != "":
            pct = float(s["avg_delta_pct"])
            if pct <= -5:
                note_bits.append(f"faster than base by {abs(pct):.2f}%")
            elif pct >= 5:
                note_bits.append(f"slower than base by {pct:.2f}%")
            else:
                note_bits.append("latency roughly equal to base")

        if int(s["exit_failures"]) > 0:
            note_bits.append(f"{s['exit_failures']} exit failure(s)")

        if int(s["unsupported"]) > int(base["unsupported"]):
            note_bits.append("more unsupported-command behavior than base")
        elif int(s["unsupported"]) < int(base["unsupported"]):
            note_bits.append("less unsupported-command behavior than base")

        if int(s["command_correct"]) > int(base["command_correct"]):
            note_bits.append("better command correctness than base")
        elif int(s["command_correct"]) < int(base["command_correct"]):
            note_bits.append("worse command correctness than base")

        if int(s["command_proof"]) > int(base["command_proof"]):
            note_bits.append("better proof-path behavior than base")
        elif int(s["command_proof"]) < int(base["command_proof"]):
            note_bits.append("worse proof-path behavior than base")

        lines.append(f"- `{alias}`: " + "; ".join(note_bits) + ".")

    notes_path.write_text("\n".join(lines) + "\n")

    print(f"Scores: {scores_path}")
    print(f"Notes:  {notes_path}")
    print()
    print(f"Base:   {base_alias}")
    print(f"Best:   {best_alias}")
    print()
    print("Top 10:")
    for alias in sorted(aliases, key=lambda a: summaries[a]["score"])[:10]:
        s = summaries[alias]
        print(
            f"{alias}\tavg={s['avg_sec']}\tdelta={s['avg_delta_pct']}%\t"
            f"unsupported={s['unsupported']}\tcorrect={s['command_correct']}/3\t"
            f"proof={s['command_proof']}/3\tscore={s['score']}"
        )


def latest_newcfg_dir() -> Path | None:
    base = Path.home() / "opencode-baselines"
    dirs = sorted(base.glob("newcfg-*"), key=lambda p: p.stat().st_mtime, reverse=True)
    return dirs[0] if dirs else None


def read_manifest(tune_dir: Path) -> list[dict[str, str]]:
    manifest_path = tune_dir / "variant-manifest.tsv"
    if not manifest_path.exists():
        raise SystemExit(f"Missing manifest: {manifest_path}")
    return load_tsv(manifest_path)


def patch_opencode_models_for_variants(tune_dir: Path) -> Path:
    opencode_path = Path.home() / ".config/opencode/opencode.json"
    if not opencode_path.exists():
        raise SystemExit(f"Missing OpenCode config: {opencode_path}")

    manifest = read_manifest(tune_dir)
    if not manifest:
        raise SystemExit(f"Empty manifest in {tune_dir}")

    base_model = manifest[0]["base_model"]
    aliases = [row["alias"] for row in manifest]

    data = json.loads(opencode_path.read_text())

    provider = data.setdefault("provider", {}).setdefault("llama-swap", {})
    models = provider.setdefault("models", {})

    base_entry = models.get(base_model)
    if not base_entry:
        base_entry = {
            "name": base_model,
            "limit": {
                "context": 49152,
                "output": 8192,
            },
        }

    backup = opencode_path.with_suffix(f".json.bak.param-tune-{time.strftime('%Y%m%d-%H%M%S')}")
    backup.write_text(opencode_path.read_text())

    for alias in aliases:
        cloned = json.loads(json.dumps(base_entry))
        cloned["name"] = alias
        models[alias] = cloned

    opencode_path.write_text(json.dumps(data, indent=2) + "\n")

    print(f"Patched OpenCode model registry: {opencode_path}")
    print(f"OpenCode backup:                 {backup}")
    print(f"Registered variants:             {len(aliases)}")
    return backup


def preflight_llama_swap_aliases(tune_dir: Path) -> None:
    manifest = read_manifest(tune_dir)
    aliases = [row["alias"] for row in manifest]

    try:
        with urllib.request.urlopen("http://127.0.0.1:9292/v1/models", timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        raise SystemExit(f"Could not query llama-swap /v1/models. Is llama-swap running with the tuning config? Error: {e}")

    available = {item.get("id") for item in data.get("data", [])}
    missing = [alias for alias in aliases if alias not in available]

    if missing:
        print("llama-swap is missing generated aliases. Start it with the tuning config:")
        print(f"  llama-swap --config {tune_dir / 'llama-swap.tuning.yaml'} --listen 127.0.0.1:9292")
        print()
        print("First missing aliases:")
        for alias in missing[:20]:
            print(f"  {alias}")
        raise SystemExit(1)

    print(f"llama-swap preflight OK: {len(aliases)} generated aliases are available.")


def run_benchmark(args: argparse.Namespace) -> None:
    tune_dir = Path(args.tune_dir).expanduser()
    aliases_file = tune_dir / "models-only.txt"
    if not aliases_file.exists():
        raise SystemExit(f"Missing aliases file: {aliases_file}")

    benchmark = Path(args.benchmark).expanduser()
    if not benchmark.exists():
        raise SystemExit(f"Benchmark script not found: {benchmark}")

    patch_opencode_models_for_variants(tune_dir)
    preflight_llama_swap_aliases(tune_dir)

    aliases = aliases_file.read_text().strip()
    env = os.environ.copy()
    env["MODELS_ONLY"] = aliases

    print()
    print(f"Running benchmark with MODELS_ONLY:")
    print(aliases)
    print()

    before = latest_newcfg_dir()

    rc = subprocess.call([str(benchmark)], env=env)

    after = latest_newcfg_dir()
    if after and after != before:
        # Preserve tuning metadata alongside the benchmark output.
        for src_name in ["variant-manifest.tsv", "models-only.txt", "llama-swap.tuning.yaml"]:
            src = tune_dir / src_name
            if src.exists():
                dst = after / src_name
                dst.write_text(src.read_text())

        print()
        print(f"Benchmark run dir: {after}")
        print()
        print("Analyze with:")
        print(f"  {Path(sys.argv[0]).expanduser()} analyze --tune-dir {tune_dir} --run-dir {after}")

    raise SystemExit(rc)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate and analyze OpenCode parameter-tuning variants.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_gen = sub.add_parser("generate")
    p_gen.add_argument("--model", required=True, help="Base llama-swap model key, e.g. qwable-27b")
    p_gen.add_argument("--config", default=str(DEFAULT_CONFIG))
    p_gen.add_argument("--out-root", default=str(DEFAULT_OUT_ROOT))
    p_gen.add_argument("--mode", choices=["focused", "oaat", "core-pairs", "qwable-stage2"], default="focused")
    p_gen.add_argument("--space", choices=["default", "qwable"], default="qwable")
    p_gen.set_defaults(func=generate)

    p_run = sub.add_parser("run")
    p_run.add_argument("--tune-dir", required=True)
    p_run.add_argument("--benchmark", default=str(DEFAULT_BENCHMARK))
    p_run.set_defaults(func=run_benchmark)

    p_analyze = sub.add_parser("analyze")
    p_analyze.add_argument("--tune-dir", required=True)
    p_analyze.add_argument("--run-dir", required=True)
    p_analyze.set_defaults(func=analyze)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
