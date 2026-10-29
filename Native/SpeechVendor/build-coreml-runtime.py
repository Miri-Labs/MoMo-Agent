# /// script
# requires-python = ">=3.12"
# ///
"""Rebuild changed translation units in pinned upstream Apple archives."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent
REVISION = "11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf"
ARCHIVES = {
    "ios": ("6b8e769cb153343270fdccbe92e3b3db0d1c421d67fa0989ab01fdf5b2fcf2de",
            "2c2299acbb461d26d4bac4bc85985d40e7c7177ed6072703ae0846d88b0b4599"),
    "macos": ("93f7a064abe99e0d6185a88c5b36ce18c4bff35cd0d5e4e81f81151de8e3e7e5",
              "cb0b0bec912c77229517c463e28a3fac9674c521f9599919efff1ef2b42f3da0"),
}


def run(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("Upstream source does not match the pinned patch")
    return text.replace(old, new, 1)


def prepare_source(source, scratch):
    if run("git", "-C", source, "rev-parse", "HEAD") != REVISION:
        raise ValueError("Unexpected sherpa source revision")
    session = run("git", "-C", source, "show", f"{REVISION}:sherpa-onnx/csrc/session.cc") + "\n"
    session = replace_once(session, """      uint32_t coreml_flags = 0;
      (void)OrtSessionOptionsAppendExecutionProvider_CoreML(sess_opts,
                                                            coreml_flags);""", """      // MoMo: ORT 1.28.2 supports the modern provider API and persistent cache.
      // Pass the provider file's remaining options after session keys were consumed.
      config.erase("DEBUG");
      if (!config.count("ModelFormat")) config["ModelFormat"] = "MLProgram";
      if (!config.count("MLComputeUnits")) config["MLComputeUnits"] = "ALL";
      sess_opts.AppendExecutionProvider("CoreML", config);""")
    session = replace_once(session, "  sess_opts.SetInterOpNumThreads(num_threads);",
        """  sess_opts.SetInterOpNumThreads(num_threads);
  // All idle speech sessions, including VAD and Nano's CPU stages, must sleep.
  for (const char *key : {"session.intra_op.allow_spinning",
                          "session.inter_op.allow_spinning"}) {
    if (!config.count(std::string("SessionConfig.") + key)) {
      sess_opts.AddConfigEntry(key, "0");
    }
  }""")
    (scratch / "session.cc").write_text(session)
    nano = run("git", "-C", source, "show", f"{REVISION}:sherpa-onnx/csrc/offline-funasr-nano-model.cc") + "\n"
    # Released dynamic INT8 decoder fails MLProgram compilation. Keep the original
    # weights and KV-cache implementation; only the encoder requests Core ML.
    for stage in ("llm", "embedding"):
        old = f"sess_opts_{stage}_(GetSessionOptions(config))"
        if nano.count(old) != 2:
            raise ValueError("Unexpected Nano session constructors")
        nano = nano.replace(old, f"""sess_opts_{stage}_(config.provider.rfind("coreml", 0) == 0
            ? GetSessionOptions(config.num_threads, "cpu") : GetSessionOptions(config))""")
    (scratch / "offline-funasr-nano-model.cc").write_text(nano)


def cached_archive(cache, downloads, name, url, expected):
    cached = cache / name
    if not cached.exists():
        downloads.mkdir(parents=True, exist_ok=True)
        cached = downloads / url.rsplit("/", 1)[1]
        if not cached.exists():
            partial = cached.with_suffix(".download")
            urllib.request.urlretrieve(url, partial)
            if digest(partial) != expected:
                raise ValueError(f"Archive checksum mismatch: {url}")
            partial.replace(cached)
    if digest(cached) != expected:
        raise ValueError(f"Archive checksum mismatch: {name}")
    return cached


def build(source, scratch, output):
    scratch.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    prepare_source(source, scratch)
    cache = Path.home() / "Library/Caches/org.swift.swiftpm/artifacts"
    reports = []
    for platform, (expected, ort_expected) in ARCHIVES.items():
        name = f"https___github_com_k2_fsa_sherpa_onnx_releases_download_xcframework_sherpa_onnx_v1_13_8_{platform}_static_xcframework_zip"
        official = cached_archive(cache, scratch / "downloads", name,
            f"https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-{platform}-static.xcframework.zip", expected)
        directory = scratch / platform
        # ditto preserves the official versioned macOS framework symlinks.
        run("ditto", "-xk", official, directory)
        ort_name = f"https___github_com_csukuangfj_onnxruntime_libs_releases_download_v1_28_2_onnxruntime_{platform}_static_xcframework_1_28_2_xcframework_zip"
        ort = cached_archive(cache, scratch / "downloads", ort_name,
            f"https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/onnxruntime-{platform}-static-xcframework-1.28.2.xcframework.zip", ort_expected)
        ort_dir = scratch / f"ort-{platform}"
        with zipfile.ZipFile(ort) as archive:
            for entry in archive.infolist():
                if "/Headers/" in entry.filename and not entry.is_dir():
                    archive.extract(entry, ort_dir)
        framework = directory / "sherpa-onnx.xcframework"
        for binary in framework.glob("*/SherpaOnnxC.framework/SherpaOnnxC"):
            slice_name = binary.parent.parent.name
            sdk = "macosx" if platform == "macos" else ("iphonesimulator" if "simulator" in slice_name else "iphoneos")
            headers = next(p for p in ort_dir.glob(f"*/{slice_name}/onnxruntime.framework/**/Headers") if p.is_dir())
            architectures = run("lipo", "-archs", binary).split()
            thin_libraries = []
            for arch in architectures:
                build_dir = scratch / "objects" / platform / slice_name / arch
                build_dir.mkdir(parents=True, exist_ok=True)
                library = build_dir / "libsherpa.a"
                if len(architectures) > 1:
                    run("lipo", binary, "-thin", arch, "-output", library)
                else:
                    shutil.copyfile(binary, library)
                members = run("ar", "-t", library).splitlines()
                filenames = ("session.cc", "offline-funasr-nano-model.cc")
                for name in (f"{name}.o" for name in filenames):
                    if members.count(name) != 1:
                        raise ValueError(f"Expected exactly one {name} in {slice_name}")
                target = f"{arch}-apple-macos14.0" if sdk == "macosx" else f"{arch}-apple-ios18.0" + ("-simulator" if sdk == "iphonesimulator" else "")
                for filename in filenames:
                    obj = build_dir / f"{filename}.o"
                    run("xcrun", "--sdk", sdk, "clang++", "-std=c++17", "-O3", "-DNDEBUG",
                        "-fvisibility=hidden", "-DSHERPA_ONNX_ENABLE_TTS=1",
                        "-DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=1", "-target", target,
                        "-isysroot", run("xcrun", "--sdk", sdk, "--show-sdk-path"),
                        "-I", source, "-I", headers, "-I", scratch / "include",
                        "-c", scratch / filename, "-o", obj)
                    run("ar", "-r", library, obj)
                run("ranlib", library)
                thin_libraries.append(library)
            if len(thin_libraries) > 1:
                run("lipo", "-create", *thin_libraries, "-output", binary)
            else:
                shutil.copyfile(thin_libraries[0], binary)
        destination = output / f"{platform}.xcframework"
        if destination.exists():
            raise FileExistsError(destination)
        shutil.copytree(framework, destination, symlinks=True)
        reports.append({"platform": platform, "source": REVISION, "upstreamArchiveSHA256": expected,
            "onnxRuntimeArchiveSHA256": ort_expected, "builderSHA256": digest(Path(__file__)),
            "patchedSourceSHA256": {name: digest(scratch / name)
                for name in ("session.cc", "offline-funasr-nano-model.cc")},
            "xcode": run("xcodebuild", "-version")})
    (output / "build-provenance.json").write_text(json.dumps(reports, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build(args.source.resolve(), args.scratch.resolve(), args.output.resolve())
