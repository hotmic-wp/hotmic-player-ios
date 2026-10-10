#!/usr/bin/env python3
"""Export the partner API from a compiled module, excluding Benchmark SPI."""
import argparse
import json
import pathlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--module-dir', help='Compiled simulator modules for swift-symbolgraph-extract')
parser.add_argument('--derived-data', help='DerivedData from xcodebuild docbuild; read its arm64 symbol graphs')
parser.add_argument('--output', default='docs/PUBLIC_API.md')
parser.add_argument('--graphs', default='.bench/review-symbolgraphs')
args = parser.parse_args()
if bool(args.module_dir) == bool(args.derived_data):
    parser.error('Pass exactly one of --module-dir or --derived-data')

nominal = {'swift.struct', 'swift.class', 'swift.enum', 'swift.protocol'}

def spell(symbol):
    return ''.join(fragment['spelling'] for fragment in symbol['declarationFragments'])

def load_graph_files(directory, module):
    payloads = []
    for graph in [directory / f'{module}.symbols.json', *directory.glob(f'{module}@*.symbols.json')]:
        payloads.append(json.loads(graph.read_text()))
    return payloads

def public_symbols(symbols):
    exported = {}
    for symbol in symbols:
        precise = symbol['identifier']['precise']
        if '::SYNTHESIZED::' in precise or symbol['kind']['identifier'] == 'swift.extension':
            continue
        if 'location' in symbol and not symbol.get('isSPI', False):
            exported[precise] = symbol
    return exported

def docbuild_graph_dir(module):
    """One arm64 directory per module, written while compiling documentation."""
    derived = pathlib.Path(args.derived_data)
    matches = [
        path.parent for path in derived.rglob(f'{module}.symbols.json')
        if path.parent.name == 'arm64-apple-ios-simulator'
    ]
    if len(matches) != 1:
        raise SystemExit(
            f'{module}: expected one arm64 docbuild symbol-graph directory in {derived}, found {len(matches)}. '
            'The public API inventory is taken from that docbuild pass.')
    return matches[0]

def render_docbuild(symbol, index):
    """Match swift-symbolgraph-extract spelling from compiler-emitted graphs.

    Docbuild splits nested types across fragments and omits `any` on some
    existential positions. The committed inventory uses the extract spelling.
    """
    fragments = symbol['declarationFragments']
    parts = []
    for position, fragment in enumerate(fragments):
        spelling = fragment['spelling']
        if fragment['kind'] != 'typeIdentifier':
            parts.append(spelling)
            continue
        cursor = position - 1
        while cursor >= 0 and fragments[cursor]['kind'] == 'text' and fragments[cursor]['spelling'].strip() == '':
            cursor -= 1
        significant = fragments[cursor] if cursor >= 0 else None
        previous_spelling = significant['spelling'] if significant else ''
        previous_kind = significant['kind'] if significant else ''
        precise = fragment.get('preciseIdentifier', '')
        referenced = index.get(precise)
        if (previous_spelling != '.' and referenced and referenced['kind']['identifier'] in nominal
                and len(referenced.get('pathComponents') or []) > 1):
            spelling = '.'.join(referenced['pathComponents'])
        is_protocol = bool(referenced and referenced['kind']['identifier'] == 'swift.protocol') or (
            referenced is None and precise.endswith('P'))
        if is_protocol and not (previous_kind == 'keyword' and previous_spelling in {'any', 'some'}) \
                and not previous_spelling.endswith(' : '):
            following = fragments[position + 1]['spelling'] if position + 1 < len(fragments) else ''
            spelling = f'(any {spelling})' if following.startswith('?') else f'any {spelling}'
        parts.append(spelling)
    return ''.join(parts)

def grouped(module, symbols, render, inherited_docs=()):
    # Protocol witnesses such as View.body carry inherited docs in swift-symbolgraph-extract
    # and a sourceOrigin on the docbuild memberOf edge. A symbol with neither is undocumented.
    missing_docs = [
        symbol['pathComponents'] for precise, symbol in symbols.items()
        if not symbol.get('docComment') and precise not in inherited_docs
    ]
    if missing_docs:
        raise SystemExit(f'{module}: exported symbols without documentation: {missing_docs}')
    groups = {}
    for symbol in symbols.values():
        path = symbol['pathComponents']
        kind = symbol['kind']['identifier']
        name = '.'.join(path if kind in nominal else path[:-1])
        groups.setdefault(name, set()).add(render(symbol))
    return len(symbols), groups

def modules_from_docbuild():
    loaded = {}
    inherited = {}
    type_index = {}
    for module, _blurb in MODULES:
        payloads = load_graph_files(docbuild_graph_dir(module), module)
        symbols = [symbol for payload in payloads for symbol in payload['symbols']]
        inherited[module] = {
            relationship['source'] for payload in payloads for relationship in payload.get('relationships', [])
            if relationship.get('kind') == 'memberOf' and relationship.get('sourceOrigin')
        }
        for symbol in symbols:
            if '::SYNTHESIZED::' in symbol['identifier']['precise']:
                continue
            type_index.setdefault(symbol['identifier']['precise'], symbol)
        loaded[module] = public_symbols(symbols)
    return [
        (module, blurb, *grouped(
            module, loaded[module], lambda symbol: render_docbuild(symbol, type_index), inherited[module]))
        for module, blurb in MODULES
    ]

def modules_from_extract():
    graphs = pathlib.Path(args.graphs)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    collected = []
    for module, blurb in MODULES:
        out = graphs / module
        out.mkdir(parents=True, exist_ok=True)
        subprocess.run(['xcrun', 'swift-symbolgraph-extract', '-module-name', module,
                        '-target', 'arm64-apple-ios17.0-simulator', '-sdk', sdk, '-I', args.module_dir,
                        '-minimum-access-level', 'public', '-skip-synthesized-members', '-output-dir', str(out)],
                       check=True)
        exported = {}
        for payload in load_graph_files(out, module):
            for symbol in payload['symbols']:
                if 'location' in symbol and not symbol.get('isSPI', False):
                    exported[symbol['identifier']['precise']] = symbol
        collected.append((module, blurb, *grouped(module, exported, spell)))
    return collected

MODULES = [('HotMicPlayer', 'Playback, playlist, plug-in protocols and the headless engagement data layer.'),
           ('HotMicPlayerUI', 'Optional SwiftUI engagement components, theme and layouts. Depends only on HotMicPlayer.')]
lines = ['# Public API inventory — 1.0.0-rc.1', '',
         'Generated by `bench/export_public_api.py` from the compiled iOS simulator modules. Benchmark SPI and synthesized members are excluded. Every explicitly exported type, function, initializer, property and enum case is listed, including analytics/timeline/engagement contracts. Snapshot setters are internal; compiler fragments may omit that restriction. Behavioral contracts are in [Integration](INTEGRATION.md).', '',
         '`HMEngagement.update(_:)` is deprecated and renamed to `upsertPoll(_:)`. Removed poll IDs ignore all later upserts. Player-owned deletion records survive engagement eviction for the playlist item lifetime. Authoritative `updateReactions(_:forMessage:)` counts survive engagement eviction; `removeReaction(_:forMessage:count:isOwn:)` applies instance-local deltas. Overflow logs an error under `com.hotmic.player` / `moderation`. Queries do not mutate observed state. See [Engagement architecture](ARCHITECTURE.md#engagement-layers) for record bounds, lazy waveform reads and source-weighting fallback.', '']
lines += ["## Ranked feed refresh", "", "```swift", "// On the main actor, after each complete ranked feed response:", "player.reconcile(rankedItems)", "let change = player.lastPlaylistChange // insertedIDs, removedIDs, movedIDs, currentChanged, releasedItemIDs, releasedPlayerCount", "```", "", "Empty `reconcile` lists are no-ops. History-only responses apply removal policy and go idle without replaying history. `reconcile` preserves history, refreshes current metadata and replaces upcoming entries after current. Duplicate/empty IDs anywhere in the incoming list reject it; history IDs ranked into upcoming are ignored. If current is absent, all incoming nonhistory entries become upcoming. `removedCurrentPolicy` defaults to `.advanceNow` (next survivor, previous, idle); `.finishThenAdvance` retains current until its next end without looping, or removes it on a swipe away. Failed, failure-idle or already-ended current entries advance immediately, including failures during a finishing visit. Effective `replaceAll` clears deferred removal; identical replacements preserve it. Identical replacements are silent no-ops preserving failures, paging cursor, resume positions and loadError. Non-identical replacements with the same selected ID and canonical source preserve playback and overlapping pool assignments without currentItemChanged. Display-only refreshes preserve warm players and cached bytes. Identity uses ID plus source/format, with only configured volatileSigningQueryParameters stripped from URL identity as in the cache. Failure memory survives metadata/signing refreshes; jump(toID:) explicitly retries failed media, including the selected entry. Source changes reset saved resume positions. HMPlaylistChange has a public initializer; movedIDs includes absolute-index shifts. Edits retain overlapping prefetch work. Inactive prepared snapshots report `.warmPlayer` once a decoded frame is ready, otherwise `.resolved`; active readiness remains the activation measurement. See [Playlist management](../Sources/HotMicPlayer/HotMicPlayer.docc/PlaylistManagement.md) for full contracts.", ""]
summary = []
module_rows = modules_from_docbuild() if args.derived_data else modules_from_extract()
for module, blurb, count, groups in module_rows:
    summary.append(f'{module}: {count} symbols, {len(groups)} groups')
    lines += [f'# {module}', '', blurb, '']
    for name, declarations in sorted(groups.items()):
        lines += [f'## {name}', '', '```swift', *sorted(declarations), '```', '']
pathlib.Path(args.output).write_text('\n'.join(lines))
print('; '.join(summary), '->', args.output)
