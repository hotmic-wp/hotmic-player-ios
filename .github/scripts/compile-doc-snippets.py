#!/usr/bin/env python3
"""Typecheck every README/DocC Swift fence against the built simulator modules.

Fragments get explicit host fixtures, never SDK stubs. SwiftPM expressions are
checked against PackageDescription on the host. Third-party recipes use text
fences and must visibly say non-compiled pseudocode in their article.
"""
import argparse
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--derived-data', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
paths = sorted({*root.rglob('README.md'), *root.glob('Sources/*/*.docc/*.md'), *root.glob('docs/*.md')})
paths = [p for p in paths if p.name not in ('PUBLIC_API.md', 'ARCHITECTURE.md', 'API_REVIEW_1.0.md', 'BENCHMARKING.md') and not any(part.startswith('.') or part in ('bench', 'DerivedData') for part in p.relative_to(root).parts)]
imports = 'import SwiftUI\nimport UIKit\nimport HotMicPlayer\nimport HotMicPlayerUI\n'
fixtures = '''
@MainActor struct HostFixtures {
    var player = HMPlayer()
    var rotationIndex = 0
    var mp4URL = URL(string: "https://example.com/video.mp4")!
    var hlsURL = URL(string: "https://example.com/video.m3u8")!
    var preRollURL = URL(string: "https://example.com/ad.mp4")!
    var portraitURL: URL { mp4URL }; var landscapeURL: URL { mp4URL }; var posterURL: URL { mp4URL }
    var englishVTT: URL { mp4URL }; var spanishVTT: URL { mp4URL }
    var item: HMMediaItem { .init(id: "one", url: mp4URL) }
    var intro: HMMediaItem { item }; var replay: HMMediaItem { item }; var finale: HMMediaItem { item }
    var sponsor: HMMediaItem { item }; var bonus: HMMediaItem { item }
    var items: [HMMediaItem] { [item] }; var nextPage: [HMMediaItem] { items }
    var upcoming: [HMMediaItem] { items }; var rankedItems: [HMMediaItem] { items }; var removedIDs: Set<String> { [] }
    var navHeight: CGFloat = 54; var sheetHeight: CGFloat = 320; var safeTop: CGFloat = 62
    var fullSize = CGSize(width: 402, height: 874); var actionRailFrame = CGRect.zero
    @State var layout = HMVideoLayout()
    var feed: some View { HMVerticalFeedView(player: player) }
    var host: Self { self }; var hostControls: Self { self }
    func fire(at: CGPoint) {}; func fireFromRail() {}; func openComments() {}
    func presentShare(_ item: HMMediaItem) {}; func presentShareSheet(for item: HMMediaItem) {}
    func presentShare(_ url: URL?) {}; func openHashtag(_ tag: String) {}
    func socialData(_ item: HMMediaItem) -> any HMSocialDataSource { HMSocialModel(content: .init(title: "Fake")) }
    func socialData(for item: HMMediaItem) -> any HMSocialDataSource { socialData(item) }
    func commentSaved(_ item: HMMediaItem, _ text: String) {}
    func commentsChanged(_ item: HMMediaItem, _ opened: Bool) {}
    func update(_ event: HMAudioSessionEvent) {}
    func showPlaying() {}; func showOtherState() {}
    func animateFeed(inserted: [String], removed: [String], moved: [String]) {}
}
struct MyOverlay: View {
    let item: HMMediaItem; let paused: Bool; let videoFrame: CGRect
    var body: some View { Text(item.id) }
}
struct HostMetadata: View { let item: HMMediaItem; var body: some View { Text(item.id) } }
'''
fixture_members = fixtures[fixtures.index('{') + 1:fixtures.index('\n}')]
chunks = [imports, fixtures, '@MainActor func animateFeed(inserted: [String], removed: [String], moved: [String]) {}']
manifest = ['import PackageDescription']
count = 0
for path in paths:
    source = path.read_text()
    for index, match in enumerate(re.finditer(r'^```swift\n(.*?)^```', source, re.M | re.S), 1):
        code = match.group(1)
        label = f'{path.relative_to(root)}:{source[:match.start()].count(chr(10)) + 2}'
        # Validate imports too; moving them out of namespaces must not discard them.
        chunks.extend(re.findall(r'^import .*$', code, re.M))
        code = re.sub(r'^import .*\n', '', code, flags=re.M)
        code = re.sub(r'^// Package.swift\n', '', code)
        if code.lstrip().startswith('.task'):
            code = 'feed' + code.lstrip()
        count += 1
        if code.lstrip().startswith('.package('):
            manifest.append(f'let dependency{count}: Package.Dependency = {code.strip()}')
            continue
        if code.lstrip().startswith('.product('):
            manifest.append(f'let products{count}: [Target.Dependency] = [\n{code.strip()}\n]')
            continue
        # Declarations have their own namespace to prevent names colliding across articles.
        declarations = ('struct Feed' in code or '@MainActor struct' in code or
                        '@MainActor func' in code or '@MainActor final class ReadOnlySource' in code or
                        '@MainActor final class URLPreRolls' in code or '@MainActor final class HostAnalytics' in code)
        if declarations:
            chunk = f'@MainActor enum Snippet{count} {{\n{code}\n}}'
        elif path.name == 'BuildingYourOwnOverlay.md' and index == 1:
            code = code.replace('@State private var layout', 'var layout')
            split = code.index('HMVerticalFeedView')
            chunk = f'@MainActor struct Snippet{count} {{\n{fixture_members}\n{code[:split].replace("var layout", "override var layout")}\nfunc example() -> some View {{\nreturn {code[split:]}\n}}\n}}'
            # A stored layout belongs to the fragment's host; do not override fixture storage.
            chunk = chunk.replace('override var layout', 'var snippetLayout').replace('.hmVideoLayout(layout)', '.hmVideoLayout(snippetLayout)')
        else:
            view = bool(re.search(r'^\s*(HMVerticalFeedView|HMPlayerView|HMHitArea|HMSocialPlayerView|feed\.hm)', code, re.M))
            if path.name == 'HorizontalVideo.md' and index == 4:
                chunk = f'@MainActor final class Snippet{count}: UIViewController {{\nvar player = HMPlayer()\nfunc example() {{\n{code}\n}}\n}}'
            else:
                if view:
                    code = re.sub(r'^(\s*)(HMVerticalFeedView|HMPlayerView|HMHitArea|HMSocialPlayerView|feed\.hm)',
                                  r'\1return \2', code, count=1, flags=re.M)
                method = 'func example() async throws -> some View' if view else 'func example() async throws'
                chunk = f'@MainActor struct Snippet{count} {{\n{fixture_members}\n{method} {{\n{code}\n}}\n}}'
        chunks.append(f'// {label}\n{chunk}')
# Compile the real example source used in the docs, not a substitute protocol implementation.
chunks.append((root / 'Examples/PlayerWithUI/PlayerWithUI/MemorySource.swift').read_text())
chunks.append((root / 'Examples/CustomEngagementBackend/CustomEngagementBackend.swift').read_text())
output = args.output / 'DocSnippets.swift'
output.write_text('\n'.join(chunks))
products = args.derived_data.resolve() / 'Build/Products/Debug-iphonesimulator'
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun', 'swiftc', '-typecheck', '-swift-version', '5', '-sdk', sdk,
                '-target', 'arm64-apple-ios17.0-simulator', '-I', str(products), str(output)], check=True)
manifest_path = args.output / 'ManifestSnippets.swift'
manifest_path.write_text('\n'.join(manifest))
toolchain = pathlib.Path(subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()).parents[1]
subprocess.run(['xcrun', 'swiftc', '-typecheck', '-I', str(toolchain / 'lib/swift/pm/ManifestAPI'),
                '-package-description-version', '6.0.0', str(manifest_path)], check=True)
print(f'Compiled {count} Swift snippets from {len(paths)} README/DocC files.')
