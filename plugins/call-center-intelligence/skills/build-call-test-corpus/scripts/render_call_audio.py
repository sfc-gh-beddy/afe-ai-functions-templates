#!/usr/bin/env python3
"""Render synthetic call transcripts into audio files for AI_TRANSCRIBE testing.

Input: a CSV exported from {{EVAL_SCHEMA}}.SYNTH_AUDIO_RENDER_MANIFEST with columns
CALL_ID, RECORDING_PATH, SEQ, TRUE_ROLE, TEXT. The rows are synthetic sandbox data only.
Never run this script against a real transcript export: it writes text and audio to the
local disk.

Output: one audio file per call under --out-dir, named by RECORDING_PATH, plus
render_manifest.csv describing the variant applied to each file so the evaluation phase can
break transcription and role accuracy down by condition.

Each role is spoken by a different synthetic voice so diarization has two (or three, with
IVR) distinct speakers to find. Variants, assigned deterministically per call:
  clean        16 kHz mono, no processing
  telephony    downsampled to 8 kHz with a band-pass, the way PSTN audio sounds
  noisy        telephony plus low-level background noise
  lead_silence telephony plus 8 seconds of leading silence (tests the documented 5-second
               language-detection constraint)
  stereo_split agent on the left channel, customer on the right (tests the documented mono
               downmix; roles cannot come from channels after AI_TRANSCRIBE)

Requirements: ffmpeg, and one TTS engine: macOS `say`, or `espeak-ng` on Linux.

Upload: by default prints the PUT commands. With --upload, runs them through `snow sql`.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

VARIANTS = ["clean", "telephony", "noisy", "lead_silence", "stereo_split"]

MAC_VOICES = {"AGENT": "Samantha", "CUSTOMER": "Daniel", "IVR": "Fred", "SYSTEM": "Fred"}
ESPEAK_VOICES = {"AGENT": "en-us+f3", "CUSTOMER": "en-gb+m3", "IVR": "en-us+m7", "SYSTEM": "en-us+m7"}

GAP_SECONDS = 0.45  # pause between turns


def run(cmd: list[str]) -> None:
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(cmd)}\n{proc.stderr.strip()}")


def tts_engine() -> str:
    if platform.system() == "Darwin" and shutil.which("say"):
        return "say"
    if shutil.which("espeak-ng"):
        return "espeak-ng"
    sys.exit("No TTS engine found. Install espeak-ng, or run on macOS with `say`.")


def synth_turn(engine: str, role: str, text: str, out_wav: Path) -> None:
    """Speak one turn to a 16 kHz mono WAV."""
    raw = out_wav.with_suffix(".raw.aiff" if engine == "say" else ".raw.wav")
    if engine == "say":
        run(["say", "-v", MAC_VOICES.get(role, "Samantha"), "-o", str(raw), text])
    else:
        run(["espeak-ng", "-v", ESPEAK_VOICES.get(role, "en-us"), "-s", "160", "-w", str(raw), text])
    run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(raw), "-ar", "16000", "-ac", "1", str(out_wav)])
    raw.unlink(missing_ok=True)


def silence(path: Path, seconds: float) -> None:
    run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i",
         f"anullsrc=r=16000:cl=mono", "-t", f"{seconds}", str(path)])


def concat(parts: list[Path], out: Path) -> None:
    listing = out.with_suffix(".txt")
    listing.write_text("".join(f"file '{p.as_posix()}'\n" for p in parts))
    run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0",
         "-i", str(listing), "-c", "copy", str(out)])
    listing.unlink(missing_ok=True)


def variant_for(call_id: str) -> str:
    h = int(hashlib.md5(call_id.encode()).hexdigest(), 16)
    return VARIANTS[h % len(VARIANTS)]


def apply_variant(variant: str, mono: Path, agent_only: Path | None,
                  other_only: Path | None, out: Path) -> None:
    if variant == "clean":
        shutil.copyfile(mono, out)
        return
    if variant == "stereo_split":
        # Left = agent, right = everyone else. Built from role-isolated tracks of equal length.
        run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(agent_only), "-i", str(other_only),
             "-filter_complex", "[0:a][1:a]join=inputs=2:channel_layout=stereo[a]",
             "-map", "[a]", "-ar", "16000", str(out)])
        return
    phone = "highpass=f=300,lowpass=f=3400,aresample=8000"
    if variant == "telephony":
        run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(mono), "-af", phone, str(out)])
    elif variant == "noisy":
        run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(mono),
             "-f", "lavfi", "-i", "anoisesrc=color=pink:amplitude=0.02:r=16000",
             "-filter_complex", f"[0:a]{phone}[v];[1:a]aresample=8000[n];[v][n]amix=inputs=2:duration=first[a]",
             "-map", "[a]", str(out)])
    elif variant == "lead_silence":
        run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(mono),
             "-af", f"adelay=8000,{phone}", str(out)])
    else:
        raise ValueError(variant)


def render_call(engine: str, call_id: str, turns: list[dict], work: Path, out: Path) -> tuple[str, float]:
    """Render one call. Returns (variant, seconds)."""
    gap = work / "gap.wav"
    if not gap.exists():
        silence(gap, GAP_SECONDS)

    mono_parts: list[Path] = []
    agent_parts: list[Path] = []
    other_parts: list[Path] = []
    for t in sorted(turns, key=lambda r: int(r["SEQ"])):
        wav = work / f"{call_id}_{int(t['SEQ']):03d}.wav"
        synth_turn(engine, t["TRUE_ROLE"], t["TEXT"], wav)
        dur = float(subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(wav)],
            stdout=subprocess.PIPE, text=True).stdout.strip() or 0)
        mute = work / f"{call_id}_{int(t['SEQ']):03d}_mute.wav"
        silence(mute, dur)
        mono_parts += [wav, gap]
        if t["TRUE_ROLE"] == "AGENT":
            agent_parts += [wav, gap]
            other_parts += [mute, gap]
        else:
            agent_parts += [mute, gap]
            other_parts += [wav, gap]

    mono = work / f"{call_id}_mono.wav"
    concat(mono_parts, mono)
    variant = variant_for(call_id)
    agent_only = other_only = None
    if variant == "stereo_split":
        agent_only, other_only = work / f"{call_id}_a.wav", work / f"{call_id}_o.wav"
        concat(agent_parts, agent_only)
        concat(other_parts, other_only)

    out.parent.mkdir(parents=True, exist_ok=True)
    apply_variant(variant, mono, agent_only, other_only, out)
    seconds = float(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(out)],
        stdout=subprocess.PIPE, text=True).stdout.strip() or 0)
    return variant, seconds


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", required=True, help="CSV export of SYNTH_AUDIO_RENDER_MANIFEST")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--only-audio-only", action="store_true",
                    help="render only calls flagged audio_only (requires AUDIO_ONLY column in the CSV)")
    ap.add_argument("--limit", type=int, default=0, help="render at most N calls (0 = all)")
    ap.add_argument("--stage", help="fully qualified stage, e.g. CCI.SANDBOX.CALL_AUDIO_STAGE")
    ap.add_argument("--connection", help="snow CLI connection name for --upload")
    ap.add_argument("--upload", action="store_true", help="PUT files to --stage via `snow sql`")
    args = ap.parse_args()

    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            sys.exit(f"{tool} is required")
    engine = tts_engine()

    calls: dict[str, list[dict]] = defaultdict(list)
    paths: dict[str, str] = {}
    with open(args.manifest, newline="") as fh:
        for row in csv.DictReader(fh):
            row = {k.upper(): v for k, v in row.items()}
            if args.only_audio_only and row.get("AUDIO_ONLY", "").lower() not in ("true", "1"):
                continue
            calls[row["CALL_ID"]].append(row)
            paths[row["CALL_ID"]] = row["RECORDING_PATH"]

    call_ids = sorted(calls)
    if args.limit:
        call_ids = call_ids[: args.limit]

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    results = []
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for i, cid in enumerate(call_ids, 1):
            target = out_dir / paths[cid]
            try:
                variant, secs = render_call(engine, cid, calls[cid], work, target)
                results.append({"call_id": cid, "recording_path": paths[cid], "variant": variant,
                                "rendered_seconds": round(secs, 2), "status": "ok", "error": ""})
            except Exception as exc:  # keep going; failures are reported, not hidden
                results.append({"call_id": cid, "recording_path": paths[cid], "variant": "",
                                "rendered_seconds": 0, "status": "failed", "error": str(exc)[:300]})
            if i % 25 == 0:
                print(f"rendered {i}/{len(call_ids)}", file=sys.stderr)
            for f in work.glob(f"{cid}_*"):
                f.unlink(missing_ok=True)

    manifest_out = out_dir / "render_manifest.csv"
    with open(manifest_out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(results[0].keys()) if results else
                           ["call_id", "recording_path", "variant", "rendered_seconds", "status", "error"])
        w.writeheader()
        w.writerows(results)

    ok = sum(r["status"] == "ok" for r in results)
    print(f"rendered {ok} of {len(results)} calls; manifest at {manifest_out}")

    if args.stage:
        puts = []
        for sub in sorted({str(Path(p).parent) for p in paths.values()}):
            local = (out_dir / sub).resolve().as_posix()
            puts.append(f"PUT 'file://{local}/*.wav' @{args.stage}/{sub}/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE")
        puts.append(f"PUT 'file://{manifest_out.resolve().as_posix()}' @{args.stage}/manifest/ "
                    f"AUTO_COMPRESS=FALSE OVERWRITE=TRUE")
        if args.upload:
            for stmt in puts:
                cmd = ["snow", "sql", "-q", stmt] + (["-c", args.connection] if args.connection else [])
                run(cmd)
            print(f"uploaded to @{args.stage}")
        else:
            print("Upload with:")
            for stmt in puts:
                print("  " + stmt + ";")


if __name__ == "__main__":
    main()
