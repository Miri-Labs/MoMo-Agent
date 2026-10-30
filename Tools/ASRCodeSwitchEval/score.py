"""Score code-switching ASR runs with Mixed Error Rate (MER).

Tokenization: every Han character is one token; every Latin/digit word is one
token. MER = (S + D + I) / reference tokens, pooled over utterances (not an
average of per-utterance rates). zh-CER and en-WER are computed on the same
utterances after keeping only Han tokens or only Latin tokens on both sides.

Normalization "momo-cs-mer-v1" is applied identically to references and
hypotheses of every model:
  1. Unicode NFKC + casefold; drop tags such as [UNK], <|en|>, <unk>.
  2. Traditional -> Simplified Chinese (OpenCC t2s).
  3. Arabic numbers are spelled out (ASCEND references never contain digits):
     next to a Han character -> Chinese reading ("100多" -> 一百多, "95%" ->
     百分之九十五); otherwise, next to a Latin word -> English reading ("80
     students" -> eighty students, "2030" -> twenty thirty); a number with no
     word neighbour -> Chinese. "两" -> "二" so "两门" equals ITN output "2门".
  4. Punctuation and symbols -> space (in-word apostrophes kept); "okay" -> "ok".
  5. Runs of >= 2 single Latin letters are joined ("i s m" == "ISM").
  6. Primary metric drops filler tokens (FILLERS) on both sides; the "strict"
     metric keeps them.

Run (from the repository root):
    uv run --python 3.12 --with opencc-python-reimplemented==0.1.7 python -I \
        Tools/ASRCodeSwitchEval/score.py --corpus CORPUS_DIR --runs RUNS_DIR
"""

import argparse
import json
import random
import re
import unicodedata
from collections import defaultdict
from pathlib import Path

from opencc import OpenCC

NORMALIZATION_VERSION = "momo-cs-mer-v1"
HAN = "㐀-䶿一-鿿豈-﫿"
TOKEN = re.compile(rf"[{HAN}]|[a-z0-9]+(?:'[a-z0-9]+)*|\S")
TAG = re.compile(r"\[[^\]]*\]|<\|[^|]*\|>|<[a-z/][^>]*>")
FILLERS = set("呃嗯啊哦噢唉诶欸哎额呣") | {"um", "uh", "uhm", "hmm", "mm", "mhm", "er", "ah", "oh", "eh"}
WORD_MAP = {"okay": "ok"}
DIGITS = "零一二三四五六七八九"
T2S = OpenCC("t2s")


def small_number(value):
    """Chinese reading for 0 <= value < 10000."""
    if value == 0:
        return "零"
    out, zero = "", False
    for unit_value, unit in [(1000, "千"), (100, "百"), (10, "十"), (1, "")]:
        digit = value // unit_value % 10
        if digit == 0:
            zero = bool(out)
            continue
        if zero:
            out += "零"
            zero = False
        out += ("" if (digit == 1 and unit == "十" and not out) else DIGITS[digit]) + unit
    return out


def integer_reading(text):
    # Leading zeros or very long runs (phone numbers, codes) are read digit by digit.
    if (len(text) > 1 and text[0] == "0") or len(text) > 12:
        return "".join(DIGITS[int(char)] for char in text)
    value = int(text)
    if value < 10000:
        return small_number(value)
    out = ""
    for part, unit in [(value // 10 ** 8, "亿"), (value // 10 ** 4 % 10 ** 4, "万"), (value % 10 ** 4, "")]:
        if part:
            if out and part < 1000:
                out += "零"
            out += (integer_reading(str(part)) if part >= 10000 else small_number(part)) + unit
    return out


def number_to_chinese(match):
    whole, fraction, percent, year = match.group(1), match.group(2), match.group(3), match.group(4)
    if year:  # Four-digit year followed by 年: read digit by digit.
        return "".join(DIGITS[int(char)] for char in whole) + "年"
    reading = integer_reading(whole)
    if fraction:
        reading += "点" + "".join(DIGITS[int(char)] for char in fraction)
    return ("百分之" + reading) if percent else reading


NUMBER = re.compile(r"(\d+)(?:\.(\d+))?(%)?(?:(?<=\d{4})(年))?")
ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def english_below_thousand(value):
    words = []
    if value >= 100:
        words += [ONES[value // 100], "hundred"] + (["and"] if value % 100 else [])
        value %= 100
    if value >= 20:
        words += [TENS[value // 10]] + ([ONES[value % 10]] if value % 10 else [])
    elif value or not words:
        words.append(ONES[value])
    return words


def english_integer(text):
    if (len(text) > 1 and text[0] == "0") or len(text) > 12:
        return [ONES[int(char)] for char in text]
    value = int(text)
    # Years such as 2030 / 1998 are read as two pairs; 2000-2009 as "two thousand ...".
    if len(text) == 4 and 1100 <= value <= 2099 and not 2000 <= value <= 2009:
        high, low = divmod(value, 100)
        return english_below_thousand(high) + (["hundred"] if low == 0 else
                                               (["oh", ONES[low]] if low < 10 else english_below_thousand(low)))
    words = []
    for scale, name in [(10 ** 9, "billion"), (10 ** 6, "million"), (10 ** 3, "thousand")]:
        if value >= scale:
            words += english_below_thousand(value // scale) + [name]
            value %= scale
    if value or not words:
        words += english_below_thousand(value)
    return words


def number_to_english(match):
    whole, fraction, percent, year = match.group(1), match.group(2), match.group(3), match.group(4)
    words = english_integer(whole)
    if fraction:
        words += ["point"] + [ONES[int(char)] for char in fraction]
    if percent:
        words.append("percent")
    return " ".join(words) + (" 年" if year else "")


def neighbour(text, index, step):
    """Return 'han', 'latin' or None for the nearest non-space character in one direction."""
    while 0 <= index < len(text) and text[index].isspace():
        index += step
    if not 0 <= index < len(text):
        return None
    char = text[index]
    if re.fullmatch(f"[{HAN}]", char):
        return "han"
    return "latin" if char.isascii() and char.isalpha() else None


def spell_number(match):
    text = match.string
    sides = {neighbour(text, match.start() - 1, -1), neighbour(text, match.end(), 1)}
    if "han" not in sides and "latin" in sides and not match.group(4):
        return " " + number_to_english(match) + " "
    return " " + number_to_chinese(match) + " "


def normalize(text, drop_fillers=True):
    text = unicodedata.normalize("NFKC", text).casefold()
    text = TAG.sub(" ", text)
    text = T2S.convert(text)
    text = re.sub(r"(?<=\d),(?=\d{3})", "", text)
    text = NUMBER.sub(spell_number, text).replace("两", "二")
    text = "".join(char if char == "'" or not unicodedata.category(char)[0] in "PS" else " " for char in text)
    tokens = []
    for token in TOKEN.findall(text):
        token = token.strip("'")
        if not token:
            continue
        token = WORD_MAP.get(token, token)
        if drop_fillers and token in FILLERS:
            continue
        # Join spelled-out letters: "i s m" -> "ism".
        if len(token) == 1 and token.isascii() and token.isalpha() and tokens and tokens[-1][1]:
            tokens[-1] = (tokens[-1][0] + token, True)
            continue
        tokens.append((token, len(token) == 1 and token.isascii() and token.isalpha()))
    # A lone single letter that never joined stays a normal word.
    return [token for token, _ in tokens]


def is_han(token):
    return bool(re.fullmatch(f"[{HAN}]", token))


def is_latin(token):
    return bool(re.fullmatch(r"[a-z0-9]+(?:'[a-z0-9]+)*", token))


def edits(reference, hypothesis):
    # Same S/D/I tie-breaking as Tools/SpeechQuality/score.py: substitution, deletion, insertion.
    row = [(index, 0, 0, index) for index in range(len(hypothesis) + 1)]
    for i, ref in enumerate(reference, 1):
        new = [(i, 0, i, 0)]
        for j, hyp in enumerate(hypothesis, 1):
            if ref == hyp:
                new.append(row[j - 1])
                continue
            cost, sub, delete, insert = row[j - 1]
            substitution = (cost + 1, sub + 1, delete, insert)
            cost, sub, delete, insert = row[j]
            deletion = (cost + 1, sub, delete + 1, insert)
            cost, sub, delete, insert = new[j - 1]
            insertion = (cost + 1, sub, delete, insert + 1)
            new.append(min([substitution, deletion, insertion], key=lambda value: value[0]))
        row = new
    count, substitutions, deletions, insertions = row[-1]
    return dict(ref=len(reference), edits=count, S=substitutions, D=deletions, I=insertions)


def pool(rows):
    total = {key: sum(row[key] for row in rows) for key in ["ref", "edits", "S", "D", "I"]}
    total["rate"] = total["edits"] / total["ref"] if total["ref"] else None
    return total


def score_run(items, run_dir, present_only=False):
    outputs = {}
    for line in (run_dir / "hypotheses.jsonl").read_text().splitlines():
        if line.strip():
            row = json.loads(line)
            if row["uid"] in outputs:
                raise ValueError(f"Duplicate hypothesis {row['uid']} in {run_dir}")
            outputs[row["uid"]] = row
    unknown = set(outputs) - {item["uid"] for item in items}
    if unknown:
        raise ValueError(f"Unknown IDs in {run_dir}: {sorted(unknown)[:5]}")
    if present_only:  # Partial runs (e.g. the Swift cross-check) are scored on their own utterances only.
        items = [item for item in items if item["uid"] in outputs]
    comparisons = []
    for item in items:
        output = outputs.get(item["uid"])
        status = output["status"] if output else "missing"
        hypothesis = output["text"] if status == "completed" else ""
        ref, hyp = normalize(item["reference"]), normalize(hypothesis)
        ref_strict, hyp_strict = normalize(item["reference"], False), normalize(hypothesis, False)
        comparisons.append(dict(
            uid=item["uid"], subset=item["subset"], status=status, reference=item["reference"],
            hypothesis=hypothesis, lang=(output or {}).get("lang", ""),
            refTokens=" ".join(ref), hypTokens=" ".join(hyp),
            hypHasDigits=bool(re.search(r"\d", hypothesis)),
            # Runaway output (repetition loops / hallucinated continuations).
            runaway=len(hyp) > 2 * len(ref) + 10,
            mer=edits(ref, hyp), merStrict=edits(ref_strict, hyp_strict),
            zh=edits([t for t in ref if is_han(t)], [t for t in hyp if is_han(t)]),
            en=edits([t for t in ref if is_latin(t)], [t for t in hyp if is_latin(t)])))
    return comparisons


def summarize(comparisons):
    groups = defaultdict(list)
    for row in comparisons:
        groups[row["subset"]].append(row)
        if row["subset"].endswith("-mixed"):
            groups[row["subset"].split("-")[0] + "-mixed-all"].append(row)
    summary = {}
    for name, rows in sorted(groups.items()):
        summary[name] = dict(
            utterances=len(rows), failed=sum(row["status"] != "completed" for row in rows),
            hypothesesWithDigits=sum(row["hypHasDigits"] for row in rows),
            runaway=sum(row["runaway"] for row in rows),
            merExcludingRunaway=pool([row["mer"] for row in rows if not row["runaway"]]),
            mer=pool([row["mer"] for row in rows]), merStrict=pool([row["merStrict"] for row in rows]),
            zhCER=pool([row["zh"] for row in rows]), enWER=pool([row["en"] for row in rows]))
    return summary


BOOTSTRAP_SEED = 20261027
BOOTSTRAP_ROUNDS = 2000


def bootstrap(per_model, baseline, group):
    """Utterance-level paired bootstrap of pooled MER on the code-switched utterances."""
    uids = sorted(per_model[baseline])
    rng = random.Random(BOOTSTRAP_SEED)
    samples = [[rng.choice(uids) for _ in uids] for _ in range(BOOTSTRAP_ROUNDS)]

    def rate(rows, sample):
        edits = sum(rows[uid]["edits"] for uid in sample)
        return edits / sum(rows[uid]["ref"] for uid in sample)

    result = {}
    for model, rows in per_model.items():
        if sorted(rows) != uids:
            continue
        values = sorted(rate(rows, sample) for sample in samples)
        deltas = sorted(rate(rows, sample) - rate(per_model[baseline], sample) for sample in samples)
        low, high = int(0.025 * BOOTSTRAP_ROUNDS), int(0.975 * BOOTSTRAP_ROUNDS) - 1
        result[model] = dict(mer95=[values[low], values[high]], deltaVsBaseline95=[deltas[low], deltas[high]],
                             betterThanBaselineShare=sum(delta < 0 for delta in deltas) / BOOTSTRAP_ROUNDS)
    return dict(baseline=baseline, subset=group, rounds=BOOTSTRAP_ROUNDS, seed=BOOTSTRAP_SEED,
                models=result)


def percent(value):
    return "–" if value is None else f"{100 * value:.1f}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--runs", type=Path, required=True, help="Directory holding one subdirectory per model run")
    parser.add_argument("--present-only", action="store_true", help="Score only utterances that have hypotheses")
    parser.add_argument("--baseline", default="sensevoice-int8-20240717", help="Run name for the paired bootstrap")
    args = parser.parse_args()
    items = [json.loads(line) for line in (args.corpus / "manifest.jsonl").read_text().splitlines() if line.strip()]
    report = dict(normalizationVersion=NORMALIZATION_VERSION, fillers=sorted(FILLERS), models={})
    lines = ["| model | subset | n | MER | MER strict | zh-CER | en-WER | S/D/I (MER) | runaway | MER w/o runaway | hyp with digits | RTF | peak RSS MiB |",
             "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |"]
    per_model = {}
    for run_dir in sorted(path for path in args.runs.iterdir() if (path / "hypotheses.jsonl").exists()):
        run = json.loads((run_dir / "run.json").read_text()) if (run_dir / "run.json").exists() else {}
        comparisons = score_run(items, run_dir, args.present_only)
        summary = summarize(comparisons)
        for row in comparisons:
            if row["subset"].endswith("-mixed"):
                for group in [row["subset"], row["subset"].split("-")[0] + "-mixed-all"]:
                    per_model.setdefault(group, {}).setdefault(run_dir.name, {})[row["uid"]] = row["mer"]
        with open(run_dir / "comparisons.jsonl", "w") as handle:
            for row in comparisons:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        report["models"][run_dir.name] = dict(summary=summary, rtf=run.get("rtf"),
                                              peakRSSBytes=run.get("peakRSSBytes"),
                                              modelBytesOnDisk=run.get("modelBytesOnDisk"),
                                              loadSeconds=run.get("loadSeconds"))
        for subset, values in summary.items():
            mer = values["mer"]
            lines.append(f"| {run_dir.name} | {subset} | {values['utterances']} | {percent(mer['rate'])} | "
                         f"{percent(values['merStrict']['rate'])} | {percent(values['zhCER']['rate'])} | "
                         f"{percent(values['enWER']['rate'])} | {mer['S']}/{mer['D']}/{mer['I']} | "
                         f"{values['runaway']} | {percent(values['merExcludingRunaway']['rate'])} | "
                         f"{values['hypothesesWithDigits']} | {run.get('rtf') or 0:.3f} | "
                         f"{(run.get('peakRSSBytes') or 0) / 2 ** 20:.0f} |")
    report["bootstrap"] = {}
    for group, models in sorted(per_model.items()):
        if args.baseline not in models:
            continue
        report["bootstrap"][group] = bootstrap(models, args.baseline, group)
        lines += ["", f"Paired bootstrap on {group} vs {args.baseline} ({BOOTSTRAP_ROUNDS} rounds):", "",
                  "| model | MER 95% CI | ΔMER vs baseline 95% CI | P(better) |", "| --- | --- | --- | ---: |"]
        for model, values in report["bootstrap"][group]["models"].items():
            ci, delta = values["mer95"], values["deltaVsBaseline95"]
            lines.append(f"| {model} | {percent(ci[0])}–{percent(ci[1])} | {100 * delta[0]:+.1f}…{100 * delta[1]:+.1f} | "
                         f"{values['betterThanBaselineShare']:.2f} |")
    (args.runs / "scores.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    (args.runs / "scores.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
