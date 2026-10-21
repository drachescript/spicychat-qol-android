#!/usr/bin/env python3
"""Strict build-time parity check for shared QoL and Android's flattened assets.

Runs after update_android.ps1, before an Android build. Stdlib only.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys


def check(extensions: Path, android: Path) -> list[str]:
    problems: list[str] = []
    manifest = json.loads((extensions / 'manifest.json').read_text(encoding='utf-8-sig'))
    if not re.fullmatch(r'\d+\.\d+\.\d+', manifest.get('version','')):
        problems.append('Manifest version is not a numeric three-part release version')
    js = [p for group in manifest.get('content_scripts',[]) for p in group.get('js',[])]
    css = [p for group in manifest.get('content_scripts',[]) for p in group.get('css',[])]
    resources = [p for group in manifest.get('web_accessible_resources',[]) for p in group.get('resources',[]) if p.endswith('.js')]
    for group in manifest.get('content_scripts', []):
        if group.get('world') == 'MAIN':
            for main_path in group.get('js', []):
                if main_path != 'content/card-token-main.js':
                    problems.append(f'New MAIN-world script requires Android review: {main_path}')
    if not js: problems.append('No content scripts declared')
    if not css: problems.append('No stylesheets declared')

    def validate(paths: list[str], ext: str, target: str) -> None:
        flat: dict[str,str] = {}
        for rel in paths:
            posix = Path(rel)
            if not rel or rel.startswith('/') or '..' in posix.parts or '\\' in rel or posix.suffix.lower() != ext:
                problems.append(f'Unsafe/unexpected {ext} path: {rel}')
                continue
            fn = posix.name.casefold()
            if fn in flat and flat[fn] != rel:
                problems.append(f'Flattened asset name collision: {flat[fn]} versus {rel}')
            flat[fn] = rel
            src, dst = extensions / rel, android / target / posix.name
            if not src.is_file():
                problems.append(f'Missing extension source: {rel}')
            elif not dst.is_file():
                problems.append(f'Missing Android asset: {dst}')
            elif src.read_bytes() != dst.read_bytes():
                problems.append(f'Stale/different Android asset: {rel}')

    validate(list(dict.fromkeys(js+resources)), '.js', 'assets/js')
    validate(list(dict.fromkeys(css)), '.css', 'assets/css')
    html = (extensions / manifest.get('options_page','options.html'))
    if not html.is_file():
        problems.append(f'Missing Options page: {html}')
    else:
        text = html.read_text(encoding='utf-8-sig')
        deps = re.findall(r'<(?:script|link)\b[^>]*(?:src|href)\s*=\s*["\']([^"\']+)', text, flags=re.I)
        supported = re.compile(r'^[A-Za-z0-9_./-]+\.(?:js|css)$', re.I)
        option_names: dict[str, str] = {}
        for ref in deps:
            ref = re.split(r'[?#]', ref, maxsplit=1)[0]
            if not supported.fullmatch(ref) or ref.startswith(('/', '.')) or '..' in Path(ref).parts:
                continue
            name_key = Path(ref).name.casefold()
            if name_key in option_names and option_names[name_key] != ref:
                problems.append(f'Options asset name collision: {option_names[name_key]} versus {ref}')
            option_names[name_key] = ref
            if not (html.parent/ref).is_file():
                problems.append(f'Missing extension Options dependency: {ref}')
            dest = android / 'assets/options' / Path(ref).name
            if not dest.is_file():
                problems.append(f'Missing Android Options dependency: {ref}')
            elif ref.endswith('.js') and dest.read_bytes() != (html.parent/ref).read_bytes():
                problems.append(f'Stale Android Options script: {ref}')
            # options.css intentionally has Android-only mobile CSS appended.
        for name in ['options.html','options-bridge.js','feature-registry.js','options.js']:
            if not (android/'assets/options'/name).is_file():
                problems.append(f'Missing mandatory Android Settings file: {name}')
    dart = (android/'lib/services/js_bundle_service.dart').read_text(encoding='utf-8-sig')
    version_match = re.search(r"bundledExtensionVersion\s*=\s*'([^']+)'", dart)
    if not version_match or version_match.group(1) != manifest.get('version'):
        problems.append('Bundled extension version is not synced to current manifest')
    for path in js:
        marker = 'assets/js/' + Path(path).name
        if marker not in dart:
            problems.append(f'Unregistered bundled JavaScript: {path}')
    for path in css:
        marker = 'assets/css/' + Path(path).name
        if marker not in dart:
            problems.append(f'Unregistered bundled CSS: {path}')
    # Android's two native-bridged MAIN world scripts must still be packaged.
    for critical in ['generation-metadata-bridge.js','exact-message-counts-bridge.js','card-token-main.js']:
        if not (android/'assets/js'/critical).is_file():
            problems.append(f'Missing mandatory MAIN world helper: {critical}')
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--extension', required=True, type=Path)
    parser.add_argument('--android', required=True, type=Path)
    args = parser.parse_args()
    problems = check(args.extension.resolve(),args.android.resolve())
    if problems:
        for p in problems: print('ERROR:',p,file=sys.stderr)
        print(f'FAIL: {len(problems)} compatibility errors',file=sys.stderr)
        return 1
    print('PASS: Android assets and manifest dependencies are synchronized.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
