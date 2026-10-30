"""Validate all four languages, interpolation arguments and extracted native UI keys."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Packages/MoMoAgentKit/Sources/MoMoContracts/Resources/Localizable.xcstrings"
LANGUAGES = {"zh-Hans", "en", "ja", "ko"}
PRINTF = re.compile(r"%(?:(\d+)\$)?[-+#0 ]*(?:\d+)?(?:\.\d+)?(@|arg|lld|llu|ld|lu|d|u|lf|f)")
CJK = re.compile(r"[\u3400-\u9fff]")


def normalize(key):
    return PRINTF.sub("%@", key.replace("%%", "%"))


def arguments(value):
    value = value.replace("%%", "")
    return [match[2] for match in PRINTF.finditer(value)]


def validate_catalog(path):
    catalog = json.loads(path.read_text())
    for key, entry in catalog["strings"].items():
        assert LANGUAGES <= entry["localizations"].keys(), (path, key, "missing language")
        for language in LANGUAGES:
            unit = entry["localizations"][language]["stringUnit"]
            assert unit["state"] == "translated" and unit["value"], (path, key, language)
            # Named JS arguments may move, but no argument may disappear or appear twice.
            assert sorted(re.findall(r"\{\d+\}", key)) == sorted(re.findall(r"\{\d+\}", unit["value"])), (key, language, "JS arguments")
            if path.name == "Localizable.xcstrings":
                assert sorted(arguments(key)) == sorted(arguments(unit["value"])), (key, language, "native arguments")
    return catalog


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiled-directory", type=Path,
                        help="Also check exact compiler-emitted format keys in a DerivedData directory.")
    options = parser.parse_args()
    catalog = validate_catalog(CATALOG)
    for app in ["iPhoneApp", "WatchApp"]:
        validate_catalog(ROOT / "Apps" / app / "Resources/InfoPlist.xcstrings")
    normalized_keys = {normalize(key) for key in catalog["strings"]}
    sources = [path for folder in ["Apps", "Packages/MoMoAgentKit/Sources"]
               for path in (ROOT / folder).rglob("*.swift") if "UITest" not in path.name]
    temporary_root = ROOT / "tmp_agent_output"
    temporary_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="localization-audit-", dir=temporary_root) as temporary:
        subprocess.run(["xcrun", "xcstringstool", "extract", "--modern-localizable-strings", "--SwiftUI",
                        *map(str, sources), "--output-directory", temporary], check=True, capture_output=True)
        missing = set()
        for file in Path(temporary).glob("*.stringsdata"):
            data = json.loads(file.read_text())
            for item in data.get("tables", {}).get("Localizable", []):
                key = item["key"]
                if CJK.search(key) and normalize(key) not in normalized_keys:
                    missing.add(key)
        assert not missing, "Untranslated native keys:\n" + "\n".join(sorted(missing))
    if options.compiled_directory:
        records = 0
        missing = set()
        for file in options.compiled_directory.rglob("*.stringsdata"):
            if any("Tests.build" in part for part in file.parts):
                continue
            data = json.loads(file.read_text())
            for item in data.get("tables", {}).get("Localizable", []):
                key = item["key"]
                if CJK.search(key):
                    records += 1
                    if key not in catalog["strings"]:
                        missing.add(key)
        assert records, "No compiled native localization keys found."
        assert not missing, "Missing exact compiled keys:\n" + "\n".join(sorted(missing))
        print(f"PASS {records} exact compiled native keys, including interpolation types")
    print(f"PASS {len(catalog['strings'])} catalog entries in four languages, permission text, placeholders and native key coverage")


if __name__ == "__main__":
    main()
