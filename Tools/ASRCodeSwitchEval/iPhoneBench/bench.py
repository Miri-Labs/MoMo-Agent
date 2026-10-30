"""On-device iPhone ASR bench: can each candidate model run inside the app's runtime and limits?

The ASRBench app (App/) links the iPhone app's own speech runtime (Vendor/SherpaOnnx: patched
sherpa-onnx 1.13.8, ORT 1.28.2, 2 threads; SenseVoice with the app's Core ML EP options, Nano through
FunASRNano.cpp). Each run is one process launch, so the kernel's peak footprint belongs to one model.

Per model it runs:
  ascend/fg  100 mixed ASCEND utterances (CC BY-SA 4.0) -> device MER next to the Mac MER on the same 100
  real/fg    ~30 min of the user's own earphone audio, cut into the app's archive windows (BenchWindows)
  real/bg    the same windows (default first 80) with the app in the background (audio background mode)
and records load time, RTF, peak phys_footprint, os_proc_available_memory, CPU time and thermal state.
A run that disappears without its "done" marker is reported as killed, with any Jetsam report.

Private audio (real/) only travels between this Mac and the user's phone; everything stays under the
ignored tmp_agent_output/iphone-bench/. CS-Dialogue is never copied to the device.

Steps (from the repository root, phone connected and unlocked, Auto-Lock set to Never):
    bench() { uv run --python 3.12 python -I Tools/ASRCodeSwitchEval/iPhoneBench/bench.py "$@"; }
    bench prepare-ascend                   # 100 utterances -> data/ascend
    bench prepare-real --pull              # copy Documents/recordings from the app, cut windows -> data/real
    bench build                            # xcodegen + xcodebuild (Release, team from Config/Local.xcconfig)
    bench install                          # install ASRBench, copy models + data into its container
    bench run [--models a,b] [--plans ascend/fg,real/fg,real/bg]
    bench report                           # results table + device-vs-Mac MER (needs uv for score.py)
"""
import argparse
import array
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
OUT = ROOT / "tmp_agent_output/iphone-bench"
EVAL = ROOT / "tmp_agent_output/asr-code-switching-eval"


def phone_bundle_id():
    """MOMO_PHONE_BUNDLE_ID from the ignored Config/Local.xcconfig (personal-team installs), else the app default."""
    for name in ["Config/Local.xcconfig", "Config/App.xcconfig"]:
        path = ROOT / name
        if path.exists():
            for line in path.read_text().splitlines():
                key, _, value = line.partition("=")
                if key.strip() == "MOMO_PHONE_BUNDLE_ID" and value.strip():
                    return value.strip()
    return "com.momoagent.ios"


APP_BUNDLE = phone_bundle_id()  # the installed MoMo app (source of recordings for prepare-real --pull)
BUNDLE = APP_BUNDLE + ".asrbench"  # must match BENCH_BUNDLE_ID in App/Bench.xcconfig
SPEECH_BUNDLE = Path(os.environ.get("MOMO_SPEECH_BUNDLE", ROOT / "Models/Speech"))  # app's Speech/ (SenseVoice + Silero)

# Files each model needs on the device; nothing else is copied (e.g. Paraformer's FP32 model.onnx).
MODELS = {
    "sensevoice-int8-20240717": ["model.int8.onnx", "tokens.txt"],
    "funasr-nano-int8-20251230": ["encoder_adaptor.int8.onnx", "llm.int8.onnx", "embedding.int8.onnx", "Qwen3-0.6B"],
    "fireredasr2-aed-int8-20260226": ["encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"],
    "fireredasr2-aed-int4-b32": ["encoder.onnx", "decoder.onnx", "tokens.txt"],
    "fireredasr2-aed-int4-b128": ["encoder.onnx", "decoder.onnx", "tokens.txt"],
    "x-asr-offline-punct-int8-20260603": ["encoder-epoch-99-avg-1.int8.onnx", "decoder-epoch-99-avg-1.onnx",
                                          "joiner-epoch-99-avg-1.int8.onnx", "tokens.txt"],
    "x-asr-streaming-480ms-punct-int8-20260605": ["encoder.int8.onnx", "decoder.onnx", "joiner.int8.onnx", "tokens.txt"],
    "paraformer-zh-int8-20240309": ["model.int8.onnx", "tokens.txt"],
}
# Mac hypotheses on ASCEND for the same 100 utterances (same harness settings, CPU provider).
MAC_HYPOTHESES = {
    "funasr-nano-int8-20251230": EVAL / "nano-app-runtime/score-ascend/funasr-nano-app-runtime",
    "fireredasr2-aed-int4-b32": EVAL / "runs-ext/ascend/fireredasr2-aed-int4-b32",
    "fireredasr2-aed-int4-b128": EVAL / "runs-ext/ascend/fireredasr2-aed-int4-b128",
    "x-asr-offline-punct-int8-20260603": EVAL / "runs-ext/ascend/x-asr-offline-punct-int8-20260603",
    "x-asr-streaming-480ms-punct-int8-20260605": EVAL / "runs-ext/ascend/x-asr-streaming-480ms-punct-int8-20260605",
}
PLANS = ["ascend/fg", "real/fg", "real/bg"]
BACKGROUND_LIMIT = 80  # windows in real/bg, about 11 min of speech


def log(message):
    print(time.strftime("%H:%M:%S"), message, flush=True)


def devicectl(*args, json_output=False, check=True, timeout=900):
    command = ["xcrun", "devicectl", *map(str, args)]
    if not json_output:
        return subprocess.run(command, check=check, capture_output=True, text=True, timeout=timeout)
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as handle:
        path = handle.name
    try:
        subprocess.run(command + ["--json-output", path], check=check, capture_output=True, text=True, timeout=timeout)
        return json.loads(Path(path).read_text() or "{}")
    finally:
        os.unlink(path)


def device_id(args):
    if args.device:
        return args.device
    devices = devicectl("list", "devices", json_output=True)["result"]["devices"]
    for device in devices:
        properties = device.get("hardwareProperties", {})
        if properties.get("platform") == "iOS" and properties.get("reality") == "physical" \
                and device.get("connectionProperties", {}).get("tunnelState") != "unavailable":
            return properties["udid"]
    sys.exit("No connected iPhone; connect it by cable and unlock it")


def write_floats(path, chunks):
    with open(path, "wb") as handle:
        for chunk in chunks:
            chunk.tofile(handle)


def prepare_ascend(args):
    rows = [json.loads(line) for line in (EVAL / "corpus-ascend-v1/manifest.jsonl").read_text().splitlines() if line]
    selected = []
    for subset in ["ascend-test-mixed", "ascend-val-mixed"]:
        pool = sorted((row for row in rows if row["subset"] == subset), key=lambda row: row["uid"])
        step = len(pool) / 50
        selected += [pool[int(i * step)] for i in range(50)]
    out = OUT / "data/ascend"
    out.mkdir(parents=True, exist_ok=True)
    index, chunks, offset = [], [], 0
    for row in selected:
        with wave.open(str(EVAL / "corpus-ascend-v1" / row["audio"])) as source:
            assert source.getframerate() == 16000 and source.getnchannels() == 1 and source.getsampwidth() == 2
            pcm = array.array("h", source.readframes(source.getnframes()))
        floats = array.array("f", (value / 32768 for value in pcm))
        index.append(dict(uid=row["uid"], subset=row["subset"], offset=offset, count=len(floats)))
        chunks.append(floats)
        offset += len(floats)
    write_floats(out / "audio.f32", chunks)
    (out / "index.json").write_text(json.dumps(index, indent=1))
    log(f"ascend: {len(index)} utterances, {offset / 16000:.0f} s -> {out}")


def prepare_real(args):
    recordings = OUT / "recordings"
    if args.pull:
        device = device_id(args)
        shutil.rmtree(recordings, ignore_errors=True)
        devicectl("device", "copy", "from", "--device", device, "--domain-type", "appDataContainer",
                  "--domain-identifier", APP_BUNDLE, "--source", "Documents/recordings", "--destination", recordings)
    build = OUT / "benchwindows-build"
    subprocess.run(["swift", "build", "-c", "release", "--package-path", HERE / "BenchWindows",
                    "--scratch-path", build], check=True)
    subprocess.run([build / "out/Products/Release/BenchWindows", "--recordings", recordings,
                    "--speech-bundle", SPEECH_BUNDLE, "--output", OUT / "data/real",
                    "--target-minutes", str(args.minutes)], check=True)


def build(args):
    project = OUT / "xcode/App"  # same depth as App/project.yml, so relative package paths resolve
    project.mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcodegen", "--spec", HERE / "App/project.yml", "--project", project], check=True)
    subprocess.run(["xcodebuild", "-project", project / "ASRBench.xcodeproj", "-scheme", "ASRBench",
                    "-configuration", "Release", "-destination", "generic/platform=iOS",
                    "-derivedDataPath", OUT / "DerivedData", "-allowProvisioningUpdates", "build"], check=True)


def app_path():
    return OUT / "DerivedData/Build/Products/Release-iphoneos/ASRBench.app"


def install(args):
    device = device_id(args)
    devicectl("device", "install", "app", "--device", device, app_path())
    stage = OUT / "stage"
    shutil.rmtree(stage, ignore_errors=True)
    for key in selected_models(args):
        for name in MODELS[key]:
            source, target = EVAL / "models" / key / name, stage / "models" / key / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, target, copy_function=os.link)
            else:
                os.link(source, target)
    for task in ["ascend", "real"]:
        for name in ["index.json", "audio.f32"]:
            (stage / "data" / task).mkdir(parents=True, exist_ok=True)
            os.link(OUT / "data" / task / name, stage / "data" / task / name)
    # File by file, skipping files already on the device with the same size, so an interrupted copy resumes.
    files = sorted(path for path in stage.rglob("*") if path.is_file())
    total = sum(path.stat().st_size for path in files)
    copied = 0
    for path in files:
        relative = path.relative_to(stage)
        existing = remote_sizes(device, f"Documents/{relative.parent}")
        if existing.get(path.name) != path.stat().st_size:
            log(f"copy {relative} ({path.stat().st_size / 2 ** 20:.0f} MiB)")
            devicectl("device", "copy", "to", "--device", device, "--domain-type", "appDataContainer",
                      "--domain-identifier", BUNDLE, "--source", path, "--destination", f"Documents/{relative}",
                      timeout=3600)
        copied += path.stat().st_size
        log(f"{copied / total:.0%} of {total / 2 ** 30:.1f} GiB on the device")
    log("installed")


def selected_models(args):
    keys = args.models.split(",") if args.models else list(MODELS)
    unknown = set(keys) - set(MODELS)
    if unknown:
        sys.exit(f"Unknown models: {sorted(unknown)}")
    return keys


def remote_sizes(device, subdirectory):
    result = devicectl("device", "info", "files", "--device", device, "--domain-type", "appDataContainer",
                       "--domain-identifier", BUNDLE, "--subdirectory", subdirectory, json_output=True, check=False)
    return {Path(item.get("relativePath", item.get("name", ""))).name: item.get("metadata", {}).get("size")
            for item in result.get("result", {}).get("files", [])}


def remote_files(device, subdirectory):
    return set(remote_sizes(device, subdirectory))


def bench_running(device):
    result = devicectl("device", "info", "processes", "--device", device, json_output=True, check=False)
    return any("ASRBench.app/" in item.get("executable", "") for item in result.get("result", {}).get("runningProcesses", []))


def fetch(device, source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    devicectl("device", "copy", "from", "--device", device, "--domain-type", "appDataContainer",
              "--domain-identifier", BUNDLE, "--source", source, "--destination", destination, check=False)


def jetsam_reports(device, since, destination):
    listing = devicectl("device", "info", "files", "--device", device, "--domain-type", "systemCrashLogs",
                        json_output=True, check=False)
    found = []
    for item in listing.get("result", {}).get("files", []):
        name = item.get("relativePath", "")
        if ("JetsamEvent" in name or "ASRBench" in name) and name.endswith(".ips"):
            found.append(name)
    destination.mkdir(parents=True, exist_ok=True)
    kept = []
    for name in found:
        target = destination / Path(name).name
        devicectl("device", "copy", "from", "--device", device, "--domain-type", "systemCrashLogs",
                  "--source", name, "--destination", target, check=False)
        if target.exists() and target.stat().st_mtime >= since - 60:
            kept.append(target.name)
        elif target.exists():
            target.unlink()
    return kept


def run(args):
    device = device_id(args)
    plans = args.plans.split(",") if args.plans else PLANS
    results = OUT / "results"
    for key in selected_models(args):
        for plan in plans:
            task, phase = plan.split("/")
            name = f"{key}--{task}-{phase}"
            local = results / name
            if (local / "done").exists() and not args.force:
                log(f"skip {name} (done)")
                continue
            shutil.rmtree(local, ignore_errors=True)
            command = ["device", "process", "launch", "--device", device, "--terminate-existing", BUNDLE,
                       "--bench-model", key, "--bench-task", task, "--bench-phase", phase, "--bench-run", name]
            if phase == "bg":
                command += ["--bench-limit", str(args.background_limit)]
            log(f"start {name}")
            started = time.time()
            devicectl(*command)
            if phase == "bg":
                time.sleep(4)
                devicectl("device", "process", "launch", "--device", device, "com.apple.Preferences")
            outcome = "timeout"
            while time.time() - started < args.timeout:
                time.sleep(15)
                files = remote_files(device, f"Documents/results/{name}")
                if "done" in files:
                    outcome = "done"
                    break
                if "failed.json" in files:
                    outcome = "failed"
                    break
                if not bench_running(device):
                    time.sleep(5)  # the done marker may have been written just before exit
                    files = remote_files(device, f"Documents/results/{name}")
                    outcome = "done" if "done" in files else "killed"
                    break
            fetch(device, f"Documents/results/{name}", local)
            status = dict(outcome=outcome, wallSeconds=time.time() - started)
            if outcome == "killed":
                status["crashReports"] = jetsam_reports(device, started, local / "crash-reports")
            (local / "status.json").write_text(json.dumps(status, indent=1))
            log(f"{outcome} {name} after {status['wallSeconds']:.0f} s")
            if outcome != "done" and args.stop_on_failure:
                sys.exit(1)
            time.sleep(args.pause)


def gib(value):
    return f"{value / 2 ** 30:.2f}" if value else "–"


def report(args):
    results = OUT / "results"
    real_stats = json.loads((OUT / "data/real/stats.json").read_text())
    window_ratio = real_stats["windowContextSeconds"] / real_stats["recordedSeconds"]
    score = OUT / "score"
    shutil.rmtree(score, ignore_errors=True)
    uids = {row["uid"] for row in json.loads((OUT / "data/ascend/index.json").read_text())}
    for key in MODELS:
        device_run = results / f"{key}--ascend-fg"
        if (device_run / "hypotheses.jsonl").exists():
            (score / "device" / key).mkdir(parents=True)
            shutil.copy(device_run / "hypotheses.jsonl", score / "device" / key)
        mac = MAC_HYPOTHESES.get(key, EVAL / "scores-ext/ascend" / key)
        if (mac / "hypotheses.jsonl").exists():
            (score / "mac" / key).mkdir(parents=True)
            rows = [line for line in (mac / "hypotheses.jsonl").read_text().splitlines()
                    if line and json.loads(line)["uid"] in uids]
            (score / "mac" / key / "hypotheses.jsonl").write_text("\n".join(rows) + "\n")
    mer = {}
    for side in ["device", "mac"]:
        if not (score / side).exists():
            continue
        subprocess.run(["uv", "run", "--python", "3.12", "--with", "opencc-python-reimplemented==0.1.7", "python", "-I",
                        ROOT / "Tools/ASRCodeSwitchEval/score.py", "--corpus", EVAL / "corpus-ascend-v1",
                        "--runs", score / side, "--present-only"], check=True, capture_output=True)
        scores = json.loads((score / side / "scores.json").read_text())
        for key, values in scores["models"].items():
            mer[(side, key)] = values["summary"].get("ascend-mixed-all", {}).get("mer", {}).get("rate")

    def load(key, plan):
        directory = results / f"{key}--{plan.replace('/', '-')}"
        status = json.loads((directory / "status.json").read_text()) if (directory / "status.json").exists() else {}
        run_info = json.loads((directory / "run.json").read_text()) if (directory / "run.json").exists() else {}
        return status, run_info

    lines = ["| model | ascend/fg | real/fg | real/bg | load s (cold) | peak footprint GiB fg / bg | "
             "min headroom GiB | RTF real fg / bg | 8 h recording takes | MER 100 ASCEND device / Mac |",
             "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for key in MODELS:
        runs = {plan: load(key, plan) for plan in PLANS}
        if not any(status for status, _ in runs.values()):
            continue
        outcome = {plan: (status.get("outcome") or "–") for plan, (status, _) in runs.items()}
        a, f, b = (runs[plan][1] for plan in PLANS)
        loads = [r.get("loadSeconds") for r in (a, f, b) if r.get("loadSeconds") is not None]
        headroom = [r.get("minimumAvailable") for r in (a, f, b) if r.get("minimumAvailable")]
        rtf = f.get("rtf")
        hours = f"{8 * 3600 * window_ratio * rtf / 3600:.1f} h" if rtf else "–"
        device_mer, mac_mer = mer.get(("device", key)), mer.get(("mac", key))
        lines.append(
            f"| {key} | {outcome['ascend/fg']} | {outcome['real/fg']} | {outcome['real/bg']} | "
            f"{loads[0]:.1f} | {gib(max(a.get('peakFootprint', 0), f.get('peakFootprint', 0)))} / "
            f"{gib(b.get('peakFootprint'))} | {gib(min(headroom)) if headroom else '–'} | "
            f"{rtf or 0:.3f} / {b.get('rtf') or 0:.3f} | {hours} | "
            f"{device_mer * 100 if device_mer is not None else float('nan'):.1f} / "
            f"{mac_mer * 100 if mac_mer is not None else float('nan'):.1f} |" if loads else
            f"| {key} | {outcome['ascend/fg']} | {outcome['real/fg']} | {outcome['real/bg']} | – | – | – | – | – | – |")
    text = "\n".join(lines)
    text += (f"\n\nReal audio: {real_stats['selectedWindows']} app windows, {real_stats['selectedContextSeconds'] / 60:.0f} min "
             f"of window audio; across all {real_stats['recordedSeconds'] / 3600:.1f} h of copied recordings the app's VAD "
             f"keeps {window_ratio:.1%} as window audio, so 8 h of recording is about "
             f"{8 * window_ratio:.2f} h of decoding input.\n")
    (OUT / "report.md").write_text(text)
    print(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["prepare-ascend", "prepare-real", "build", "install", "run", "report"])
    parser.add_argument("--device")
    parser.add_argument("--models", help="comma-separated keys (default: all eight)")
    parser.add_argument("--plans", help="comma-separated from " + ",".join(PLANS))
    parser.add_argument("--pull", action="store_true", help="prepare-real: copy recordings from the app first")
    parser.add_argument("--minutes", type=float, default=30, help="prepare-real: window audio to select")
    parser.add_argument("--background-limit", type=int, default=BACKGROUND_LIMIT)
    parser.add_argument("--timeout", type=float, default=3600, help="run: seconds per run")
    parser.add_argument("--pause", type=float, default=20, help="run: seconds between runs")
    parser.add_argument("--force", action="store_true", help="run: repeat finished runs")
    parser.add_argument("--stop-on-failure", action="store_true")
    args = parser.parse_args()
    dict(prepare_ascend=prepare_ascend, prepare_real=prepare_real, build=build, install=install, run=run,
         report=report)[args.command.replace("-", "_")](args)


if __name__ == "__main__":
    main()
