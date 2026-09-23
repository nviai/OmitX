#!/usr/bin/env python3
"""Manages OmitX translations.

  scripts/l10n.py extract            Build with -emit-localized-strings, update Localizable.xcstrings
  scripts/l10n.py export             Write Localization/source.json (keys + context) for translators
  scripts/l10n.py import [lang...]   Import Localization/translations/<lang>.json into the catalog
  scripts/l10n.py validate <lang>    Check translations/<lang>.json (writes nothing)
  scripts/l10n.py prune              Drop keys the code no longer uses from translations/*.json
  scripts/l10n.py check              Report missing keys / wrong placeholders per language

Keys are the Vietnamese strings in the code (sourceLanguage "vi").
Translation file <lang>.json: {"<key>": "<translation>" | {"one": "...", "other": "..."}}  (dict = CLDR plural).

Order after changing UI strings: extract → export → translate → import → prune → check.
`prune` reads source.json, so running it before `export` deletes translations of brand-new keys.
"""
import json, os, re, subprocess, sys, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Localization", "Localizable.xcstrings")
SOURCE = os.path.join(ROOT, "Localization", "source.json")
TRANS_DIR = os.path.join(ROOT, "Localization", "translations")
LOC_DATA = os.path.join(ROOT, ".build", "locstrings")
# The paid engine lives in a separate repository. Without it the build cannot see its strings,
# so extract must NOT prune — otherwise it would delete the Pro translations.
PRO_SOURCES = os.path.join(ROOT, "Pro", "Sources", "OmitXPro")
HAS_PRO = os.path.isdir(PRO_SOURCES)

# Target languages — covering all 40 macOS localizations
# (en_AU/en_GB → en, es_419 → es, fr_CA → fr, zh_HK → zh-Hant via fallback).
LANGUAGES = ["en", "ar", "ca", "cs", "da", "de", "el", "es", "fi", "fr", "he", "hi", "hr", "hu", "id", "it", "ja",
             "ko", "ms", "nb", "nl", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk", "sl", "sv", "th", "tr", "uk",
             "zh-Hans", "zh-Hant"]
PLURAL_CATEGORIES = {"zero", "one", "two", "few", "many", "other"}
# CLDR cardinal plural categories per language
PLURALS = {
    "ar": "zero one two few many other", "cs": "one few many other", "sk": "one few many other",
    "pl": "one few many other", "ru": "one few many other", "uk": "one few many other",
    "sl": "one two few other", "hr": "one few other", "ro": "one few other", "he": "one two other",
    "ca": "one many other", "es": "one many other", "fr": "one many other", "it": "one many other",
    "pt-BR": "one many other", "pt-PT": "one many other",
    "id": "other", "ja": "other", "ko": "other", "ms": "other", "th": "other", "zh-Hans": "other", "zh-Hant": "other",
}
SPEC = re.compile(r"%(?:(\d+)\$)?(?:ll|l|h)?([@dDuUxXoOfeEgGcCsSpaA])|%%")


def specifiers(s):
    """Placeholder types in argument order (supports %1$@)."""
    out, pos = {}, 0
    for m in SPEC.finditer(s):
        if m.group(0) == "%%":
            continue
        pos += 1
        idx = int(m.group(1)) if m.group(1) else pos
        kind = m.group(2).lower().replace("u", "d").replace("i", "d")
        out[idx] = "@" if kind == "@" else ("f" if kind in "feg" else "d")
    return [out[k] for k in sorted(out)]


def load_catalog():
    if os.path.exists(CATALOG):
        return json.load(open(CATALOG))
    return {"sourceLanguage": "vi", "strings": {}, "version": "1.0"}


def save_catalog(cat):
    cat["strings"] = dict(sorted(cat["strings"].items(), key=lambda kv: kv[0]))
    with open(CATALOG, "w") as f:
        json.dump(cat, f, ensure_ascii=False, indent=2, separators=(",", " : "))
        f.write("\n")


def extract():
    subprocess.run(["rm", "-rf", LOC_DATA])
    os.makedirs(LOC_DATA, exist_ok=True)
    # Force a full recompile so the compiler emits .stringsdata for every file
    sources = glob.glob(os.path.join(ROOT, "Sources", "**", "*.swift"), recursive=True)
    if HAS_PRO:
        sources += glob.glob(os.path.join(PRO_SOURCES, "**", "*.swift"), recursive=True)
    for src in sources:
        os.utime(src)
    subprocess.run(["swift", "build", "-Xswiftc", "-emit-localized-strings",
                    "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", LOC_DATA], cwd=ROOT, check=True)
    keys = {}
    for path in glob.glob(os.path.join(LOC_DATA, "*.stringsdata")):
        data = json.load(open(path))
        src = os.path.relpath(data.get("source", ""), ROOT)
        for entry in data.get("tables", {}).get("Localizable", []):
            k = entry["key"]
            if not re.search(r"[^\W\d_]", SPEC.sub("", k)):  # skip empty / placeholder-only keys
                continue
            line = entry.get("location", {}).get("startingLine")
            keys.setdefault(k, []).append(f"{src}:{line}")
    cat = load_catalog()
    strings = cat["strings"]
    added = [k for k in keys if k not in strings]
    removed = [k for k in strings if k not in keys]
    if not HAS_PRO and removed:
        # The community build cannot see Pro strings — keep them rather than delete by mistake.
        print(f"⚠︎ No Pro/ — keeping {len(removed)} keys not seen in this build.")
        removed = []
    for k in added:
        strings[k] = {}
    for k in removed:
        del strings[k]
    for k, locs in keys.items():
        strings[k]["comment"] = "; ".join(sorted(set(locs))[:3])
        strings[k].pop("extractionState", None)
    save_catalog(cat)
    print(f"{len(strings)} keys  (+{len(added)} new, -{len(removed)} removed)"
          + ("" if HAS_PRO else "  [no Pro/]"))


def export():
    cat = load_catalog()
    out = []
    for k, v in cat["strings"].items():
        locs = v.get("comment", "")
        context = []
        for loc in locs.split("; ")[:2]:
            f, _, line = loc.rpartition(":")
            try:
                lines = open(os.path.join(ROOT, f)).read().splitlines()
                context.append(lines[int(line) - 1].strip()[:160])
            except Exception:
                pass
        out.append({"key": k, "placeholders": specifiers(k), "context": context,
                    "count": bool(re.search(r"%(?:\d+\$)?lld", k)) and len(specifiers(k)) == 1})
    json.dump(out, open(SOURCE, "w"), ensure_ascii=False, indent=1)
    print(f"Wrote {len(out)} keys → {os.path.relpath(SOURCE, ROOT)}")


def validate(key, value):
    """Returns an error (str) or None."""
    want = sorted(specifiers(key))
    values = value.values() if isinstance(value, dict) else [value]
    if isinstance(value, dict):
        bad = set(value) - PLURAL_CATEGORIES
        if bad or "other" not in value:
            return f"invalid plural categories: {sorted(value)}"
    for v in values:
        if not isinstance(v, str) or not v.strip():
            return "empty"
        got = sorted(specifiers(v))
        # The plural "one" form may omit the number (e.g. "One item")
        if got != want and not (isinstance(value, dict) and got == [] and want == ["d"]):
            return f"placeholder {got} ≠ {want}: {v!r}"
    return None


def validate_file(lang):
    """Checks translations/<lang>.json. Returns a list of errors."""
    keys = [e["key"] for e in json.load(open(SOURCE))]
    data = json.load(open(os.path.join(TRANS_DIR, f"{lang}.json")))
    allowed = set(PLURALS.get(lang, "one other").split())
    errors = [f"MISSING key: {k!r}" for k in keys if k not in data]
    errors += [f"UNKNOWN key (not in source.json): {k!r}" for k in data if k not in keys]
    for k in keys:
        if k not in data:
            continue
        v = data[k]
        err = validate(k, v)
        if not err and isinstance(v, dict) and not set(v) <= allowed:
            err = f"plural category {sorted(set(v) - allowed)} is not used in {lang} (valid: {sorted(allowed)})"
        if err:
            errors.append(f"{k!r}: {err}")
    return errors


def validate_cmd(langs):
    bad = False
    for lang in langs:
        errors = validate_file(lang)
        for e in errors:
            print(f"  [{lang}] {e}")
        print(f"{lang}: {'OK' if not errors else f'{len(errors)} errors'}")
        bad |= bool(errors)
    sys.exit(1 if bad else 0)


def import_(langs):
    cat = load_catalog()
    langs = langs or [os.path.splitext(os.path.basename(p))[0] for p in sorted(glob.glob(os.path.join(TRANS_DIR, "*.json")))]
    for lang in langs:
        path = os.path.join(TRANS_DIR, f"{lang}.json")
        data = json.load(open(path))
        ok = errors = 0
        for key, value in data.items():
            if key not in cat["strings"]:
                continue
            err = validate(key, value)
            if err:
                errors += 1
                print(f"  [{lang}] {key!r}: {err}")
                continue
            loc = cat["strings"][key].setdefault("localizations", {})
            if isinstance(value, dict):
                loc[lang] = {"variations": {"plural": {
                    cat_: {"stringUnit": {"state": "translated", "value": v}} for cat_, v in value.items()}}}
            else:
                loc[lang] = {"stringUnit": {"state": "translated", "value": value}}
            ok += 1
        print(f"{lang:8s} {ok} ok, {errors} errors")
    # Write the Vietnamese value (= the key) for every string so vi.lproj is complete.
    # Otherwise macOS falls back to CFBundleDevelopmentRegion (en) — e.g. "38 apps" in the Vietnamese UI.
    for key, entry in cat["strings"].items():
        entry.setdefault("localizations", {})["vi"] = {"stringUnit": {"state": "translated", "value": key}}
    save_catalog(cat)


def prune():
    keys = {e["key"] for e in json.load(open(SOURCE))}
    for path in sorted(glob.glob(os.path.join(TRANS_DIR, "*.json"))):
        data = json.load(open(path))
        stale = [k for k in data if k not in keys]
        if stale:
            for k in stale:
                del data[k]
            json.dump(data, open(path, "w"), ensure_ascii=False, indent=1)
        print(f"{os.path.basename(path):12s} -{len(stale)}")


def check():
    cat = load_catalog()
    total = len(cat["strings"])
    bad = False
    for lang in LANGUAGES:
        missing = [k for k, v in cat["strings"].items() if lang not in v.get("localizations", {})]
        status = "✓" if not missing else f"missing {len(missing)}"
        bad |= bool(missing)
        print(f"{lang:8s} {total - len(missing)}/{total} {status}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    if cmd == "validate":
        validate_cmd(sys.argv[2:])
    elif cmd == "import":
        import_(sys.argv[2:])
    else:
        {"extract": extract, "export": export, "prune": prune, "check": check}[cmd]()
