"""Emulate a duration-proportional max_new_tokens guard for FunASR Nano.

sherpa-onnx 1.13.8 fixes max_new_tokens when the recognizer is created
(set_config does not change it), so a per-window cap cannot be set at decode
time from Python. Nano decodes greedily (temperature 0), so a run with a cap of
N new tokens yields the first N tokens of the uncapped output. This script
re-tokenizes each uncapped hypothesis with Nano's own Qwen3 tokenizer and keeps
the first N = ceil(RATE * seconds) + FLOOR tokens. It then collapses any phrase
of 2-30 characters repeated four or more times in a row to two copies (a text
post-processing step the app could also apply), and writes a new run directory
that score.py can read. Re-tokenizing text can differ slightly from the
generated token IDs, so the result is an emulation, not a re-run.

    uv run --python 3.12 --with tokenizers==0.22.1 python -I Tools/ASRCodeSwitchEval/nano_guard.py \
        --run RUNS/funasr-nano-int8-20251230 --corpus CORPUS \
        --tokenizer MODELS/funasr-nano-int8-20251230/Qwen3-0.6B/tokenizer.json --output RUNS/NEW_NAME
"""

import argparse
import json
import math
import re
from pathlib import Path

from tokenizers import Tokenizer

RATE = 10.0  # Tokens per second of audio; normal speech stays well below this.
FLOOR = 16
REPEAT = re.compile(r"(.{2,30}?)\1{3,}", re.S)  # four or more copies; people do say a word three times


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rate", type=float, default=RATE)
    parser.add_argument("--floor", type=int, default=FLOOR)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit(f"Output directory must not exist: {args.output}")
    tokenizer = Tokenizer.from_file(str(args.tokenizer))
    seconds = {json.loads(line)["uid"]: json.loads(line)["seconds"]
               for line in (args.corpus / "manifest.jsonl").read_text().splitlines() if line.strip()}
    args.output.mkdir(parents=True)
    truncated, total = [], 0
    with open(args.output / "hypotheses.jsonl", "w") as handle:
        for line in (args.run / "hypotheses.jsonl").read_text().splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            total += 1
            limit = math.ceil(args.rate * seconds[row["uid"]]) + args.floor
            ids = tokenizer.encode(row["text"], add_special_tokens=False).ids
            row["guardLimitTokens"], row["tokens"] = limit, len(ids)
            text = row["text"]
            if len(ids) > limit:
                text = tokenizer.decode(ids[:limit])
                # Greedy decoding stops at the cap, so time scales with the kept share of tokens.
                row["decodeSeconds"] = row["decodeSeconds"] * limit / len(ids)
            text = REPEAT.sub(r"\1\1", text)
            if text != row["text"]:
                row["unguardedText"], row["text"] = row["text"], text
                truncated.append(row["uid"])
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    run = json.loads((args.run / "run.json").read_text()) if (args.run / "run.json").exists() else {}
    run.update(model=args.output.name, guard=dict(rate=args.rate, floor=args.floor, changed=truncated,
                                                  source=args.run.name, emulated=True))
    (args.output / "run.json").write_text(json.dumps(run, ensure_ascii=False, indent=2) + "\n")
    print(f"{len(truncated)}/{total} hypotheses changed: {truncated[:10]}")


if __name__ == "__main__":
    main()
