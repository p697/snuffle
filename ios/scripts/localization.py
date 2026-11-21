#!/usr/bin/env python3
"""String catalogs for the app, the widgets and SnuffleKit.

Source strings are Simplified Chinese, written in the Swift code; every other language lives in the catalogs.
Run after building the app (any destination), with the derived data the build used:

    python3 scripts/localization.py sync  --derived-data build/dd   # add new keys, drop removed ones
    python3 scripts/localization.py todo  > todo.json               # what still needs a translation
    python3 scripts/localization.py apply translations.json          # merge translations into the catalogs
    python3 scripts/localization.py check --derived-data build/dd   # what CI runs

`check` fails when the catalogs are out of step with the code, a language is missing or empty, a placeholder
differs from the source, or a Chinese string literal in the code is not localizable (it would stay Chinese in
every language). Mark the rare literal that must stay as written with `// l10n-ignore` on its line.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent
SOURCE = "zh-Hans"
# The languages YouMind ships. Keep in step with docs and the App Store listing.
LANGUAGES = ["en", "zh-Hant", "ja", "ko", "de", "es", "es-419", "fr", "it", "pt-BR", "pt-PT",
             "ru", "uk", "tr", "vi", "th", "hi", "ar"]
# Catalog -> (derived data target folder, Swift source folders it covers).
CATALOGS = {
    "Snuffle/Localizable.xcstrings": ("Snuffle.build/*/Snuffle.build", ["Snuffle"]),
    "SnuffleWidgets/Localizable.xcstrings": ("Snuffle.build/*/SnuffleWidgets.build", ["SnuffleWidgets"]),
    "Packages/SnuffleKit/Sources/SnuffleKit/Resources/Localizable.xcstrings":
        ("SnuffleKit.build/*/SnuffleKit*.build", ["Packages/SnuffleKit/Sources"]),
}
INFO_PLIST = "Snuffle/InfoPlist.xcstrings"
PLURAL_CATEGORIES = {"zero", "one", "two", "few", "many", "other"}
CJK = re.compile(r"[㐀-鿿]")
SPECIFIER = re.compile(r"%(?:(\d+)\$)?(lld|ld|d|@|f|\.\d+f)")


def load(path):
    return json.loads((IOS / path).read_text())


def save(path, catalog):
    # Xcode's own layout, so editing in Xcode does not reformat the whole file.
    text = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    (IOS / path).write_text(text + "\n")


def stringsdata(derived_data, pattern):
    root = Path(derived_data) / "Build" / "Intermediates.noindex"
    files = sorted(str(p) for folder in root.glob(pattern) for p in folder.rglob("*.stringsdata"))
    if not files:
        sys.exit(f"No .stringsdata under {root}/{pattern}. Build the app first (SWIFT_EMIT_LOC_STRINGS is on).")
    return files


def sync_into(derived_data, root):
    """Runs Apple's sync on the catalogs under `root`, then removes strings the code no longer uses."""
    for path, (pattern, _) in CATALOGS.items():
        target = root / path
        subprocess.run(["xcrun", "xcstringstool", "sync", str(target), "--stringsdata",
                        *stringsdata(derived_data, pattern)], check=True)
        catalog = json.loads(target.read_text())
        catalog["strings"] = {k: v for k, v in catalog["strings"].items() if v.get("extractionState") != "stale"}
        target.write_text(json.dumps(catalog))


def cmd_sync(args):
    sync_into(args.derived_data, IOS)
    for path in CATALOGS:
        save(path, load(path))
    print("Synced. Run `todo` for strings that need translations.")


def specifiers(text):
    return sorted(m.group(2) for m in SPECIFIER.finditer(text))


def units(entry):
    """(label, string unit) pairs of one language: the plain value or every plural form."""
    if "stringUnit" in entry:
        return [("", entry["stringUnit"])]
    plural = entry.get("variations", {}).get("plural", {})
    return [(f" [{form}]", value.get("stringUnit", {})) for form, value in plural.items()]


def missing(catalog):
    """(key, language) pairs without a finished translation."""
    gaps = []
    for key, entry in catalog["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        for language in LANGUAGES:
            found = units(entry.get("localizations", {}).get(language, {}))
            if not found or any(unit.get("state") != "translated" for _, unit in found):
                gaps.append((key, language))
    return gaps


def problems(catalog, path):
    errors = []
    for key, entry in catalog["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        expected = specifiers(key)
        may_be_empty = "[may be empty]" in entry.get("comment", "")
        for language, localization in entry.get("localizations", {}).items():
            for form, unit in units(localization):
                value = unit.get("value", "")
                if not value.strip() and not may_be_empty:
                    errors.append(f"{path}: {language}{form} is empty for {key!r}")
                if form and form.strip(" []") not in PLURAL_CATEGORIES:
                    errors.append(f"{path}: {language}{form} is not a plural category for {key!r}")
                if specifiers(value) != expected and not (form and specifiers(value) == []
                                                          and form.strip(" []") in {"zero", "one", "two"}):
                    errors.append(f"{path}: {language}{form} placeholders {specifiers(value)} != {expected} "
                                  f"for {key!r}")
                if language not in (SOURCE, "zh-Hant", "ja") and CJK.search(value):
                    errors.append(f"{path}: {language}{form} still has Chinese characters for {key!r}")
    return errors


def literals(text):
    """Swift string literals (single line) as (line, content with interpolations replaced by '\\0')."""
    found, i, line, n = [], 0, 1, len(text)

    def read_string(i, line):
        # `i` is just after the opening quote. Returns (content, index after closing quote, line).
        out = []
        while i < n:
            c = text[i]
            if c == "\n":
                line += 1
            if c == "\\" and i + 1 < n and text[i + 1] == "(":
                depth, i = 1, i + 2
                while i < n and depth:
                    if text[i] == '"':
                        _, i, line = read_string(i + 1, line)
                        continue
                    depth += {"(": 1, ")": -1}.get(text[i], 0)
                    i += 1
                out.append("\0")
                continue
            if c == "\\":
                out.append(text[i:i + 2])
                i += 2
                continue
            if c == '"':
                return "".join(out), i + 1, line
            out.append(c)
            i += 1
        return "".join(out), i, line

    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i)
            line += text.count("\n", i, end)
            i = n if end < 0 else end + 2
            continue
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            line += text.count("\n", i, end)
            i = n if end < 0 else end + 3
            continue
        if c == '"':
            start = line
            content, i, line = read_string(i + 1, line)
            found.append((start, content))
            continue
        i += 1
    return found


def key_pattern(key):
    """A catalog key with its placeholders as '\0', comparable with `literals` output."""
    return re.sub(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f)", "\0", key).replace("%%", "%")


def unescape(literal):
    escapes = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": "\0"}
    return re.sub(r"\\(.)", lambda m: escapes.get(m.group(1), m.group(1)), literal)


def unlocalized_literals():
    errors = []
    for path, (_, folders) in CATALOGS.items():
        strings = load(path)["strings"]
        # Keys, and source values of keys like "strip.revenue" written with `defaultValue:`.
        keys = {key_pattern(key) for key in strings} | {
            key_pattern(unit["value"]) for entry in strings.values()
            for unit in [entry.get("localizations", {}).get(SOURCE, {}).get("stringUnit", {})] if "value" in unit}
        for folder in folders:
            for swift in sorted((IOS / folder).rglob("*.swift")):
                text = swift.read_text()
                lines = text.split("\n")
                for number, content in literals(text):
                    if not CJK.search(content) or "l10n-ignore" in lines[number - 1]:
                        continue
                    if unescape(content) not in keys:
                        errors.append(f"{swift.relative_to(IOS)}:{number}: not localizable: \"{content.replace(chr(0), '…')}\"")
    return errors


def info_plist_problems():
    errors = []
    catalog = load(INFO_PLIST)
    project = (IOS / "project.yml").read_text()
    for key, value in re.findall(r"INFOPLIST_KEY_(NS\w+UsageDescription): (.+)", project):
        entry = catalog["strings"].get(key)
        if not entry:
            errors.append(f"{INFO_PLIST}: {key} is missing")
            continue
        source = entry.get("localizations", {}).get(SOURCE, {}).get("stringUnit", {}).get("value")
        if source != value.strip():
            errors.append(f"{INFO_PLIST}: {key} in {SOURCE} differs from project.yml")
    return errors


def cmd_check(args):
    errors = []
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for path in CATALOGS:
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(IOS / path, root / path)
        sync_into(args.derived_data, root)
        for path in CATALOGS:
            before, after = set(load(path)["strings"]), set(json.loads((root / path).read_text())["strings"])
            errors += [f"{path}: new string, run sync: {k!r}" for k in sorted(after - before)]
            errors += [f"{path}: no longer in the code, run sync: {k!r}" for k in sorted(before - after)]
    counted = 0
    for path in [*CATALOGS, INFO_PLIST]:
        catalog = load(path)
        counted += len(catalog["strings"])
        errors += [f"{path}: missing {language} for {key!r}" for key, language in missing(catalog)]
        errors += problems(catalog, path)
    errors += unlocalized_literals()
    errors += info_plist_problems()
    if errors:
        print("\n".join(errors))
        sys.exit(f"{len(errors)} localization problem(s).")
    print(f"{counted} strings, {len(LANGUAGES) + 1} languages: all translated.")


def cmd_todo(_):
    todo = {}
    for path in [*CATALOGS, INFO_PLIST]:
        catalog = load(path)
        for key, language in missing(catalog):
            item = todo.setdefault(key, {"comment": catalog["strings"][key].get("comment", ""), "languages": []})
            item["languages"].append(language)
    json.dump(todo, sys.stdout, ensure_ascii=False, indent=2)
    print()


def cmd_apply(args):
    """Merges {key: {language: value or {plural form: value}}} into whichever catalogs hold the key."""
    translations = json.loads(Path(args.file).read_text())
    unknown = set(translations)
    for path in [*CATALOGS, INFO_PLIST]:
        catalog = load(path)
        for key, languages in translations.items():
            if key not in catalog["strings"]:
                continue
            unknown.discard(key)
            localizations = catalog["strings"][key].setdefault("localizations", {})
            for language, value in languages.items():
                if isinstance(value, dict):
                    localizations[language] = {"variations": {"plural": {
                        form: {"stringUnit": {"state": "translated", "value": text}} for form, text in value.items()}}}
                else:
                    localizations[language] = {"stringUnit": {"state": "translated", "value": value}}
        save(path, catalog)
    if unknown:
        sys.exit("Not in any catalog: " + ", ".join(sorted(unknown)))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(required=True)
    for name, handler in [("sync", cmd_sync), ("check", cmd_check)]:
        command = commands.add_parser(name)
        command.add_argument("--derived-data", default="build/dd")
        command.set_defaults(handler=handler)
    commands.add_parser("todo").set_defaults(handler=cmd_todo)
    apply = commands.add_parser("apply")
    apply.add_argument("file")
    apply.set_defaults(handler=cmd_apply)
    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
