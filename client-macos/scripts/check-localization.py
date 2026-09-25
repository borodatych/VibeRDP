#!/usr/bin/env python3
"""Gate of the interface strings: the base catalog, the code that uses it and the languages the app seeds.

Fails on:
- a base-language string in the code outside the catalog, App/Localization.swift: such text never gets translated;
- a key of the catalog no code uses: a dead key keeps translators busy for nothing;
- a seeded language that misses a key, has a key the catalog does not know or renames a placeholder;
- a missing sample file next to the seeded languages.

Diagnostics stay out of it on purpose: the app has no log text in the base language, and none may appear in the UI.
Usage: check-localization.py <client-macos folder>
"""

import json
import pathlib
import re
import sys

CATALOG = pathlib.Path("App/Localization.swift")
CODE = ("App", "Connections", "Session")
LANGUAGES = pathlib.Path("Resources/lang")
SEEDED = ("en",)
SAMPLE = "example.jsonc"
BASE_LETTERS = re.compile("[Ѐ-ӿ]")
PLACEHOLDER = re.compile(r"\{(\w+)\}")
SERVICE_PREFIX = "$"


def catalog(root):
    """The keys of the catalog: case name, dotted key and base text."""
    source = (root / CATALOG).read_text(encoding="utf-8")
    keys = dict(re.findall(r'case (\w+) = "([\w.]+)"', source))
    texts = {
        name: bytes(text, "utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")
        for name, text in re.findall(r'case \.(\w+):\s*"((?:[^"\\]|\\.)*)"', source)
    }
    return keys, texts


def swift_files(root):
    for folder in CODE:
        yield from sorted((root / folder).rglob("*.swift"))


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    keys, texts = catalog(root)
    problems = []

    if set(keys) != set(texts):
        problems += [f"catalog: {name} has no base text" for name in sorted(set(keys) - set(texts))]

    code = {}
    for path in swift_files(root):
        if path == root / CATALOG:
            continue
        text = path.read_text(encoding="utf-8")
        code[path] = text
        for number, line in enumerate(text.splitlines(), 1):
            if BASE_LETTERS.search(line):
                problems.append(f"{path.relative_to(root)}:{number}: base-language text outside the catalog")

    everything = "\n".join(code.values())
    for name in sorted(keys):
        if not re.search(rf"\.{name}\b", everything):
            problems.append(f"catalog: {name} ({keys[name]}) is used by no code")

    dotted = {keys[name]: texts.get(name, "") for name in keys}
    for code_name in SEEDED:
        path = root / LANGUAGES / f"{code_name}.json"
        try:
            language = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            problems.append(f"{path.relative_to(root)}: unreadable: {error}")
            continue
        if not isinstance(language.get("$name"), str):
            problems.append(f"{path.relative_to(root)}: no $name")
        strings = {key: value for key, value in language.items() if not key.startswith(SERVICE_PREFIX)}
        problems += [f"{path.relative_to(root)}: {key} is missing" for key in sorted(set(dotted) - set(strings))]
        problems += [f"{path.relative_to(root)}: {key} is no key of the catalog" for key in sorted(set(strings) - set(dotted))]
        for key in sorted(set(dotted) & set(strings)):
            if set(PLACEHOLDER.findall(dotted[key])) != set(PLACEHOLDER.findall(strings[key])):
                problems.append(f"{path.relative_to(root)}: {key} has other placeholders than the base text")

    if not (root / LANGUAGES / SAMPLE).is_file():
        problems.append(f"{LANGUAGES / SAMPLE}: the sample file is missing")

    for problem in problems:
        print(f"localization: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"localization: {len(keys)} keys, all used, seeded languages complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
