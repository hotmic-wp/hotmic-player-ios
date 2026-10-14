#!/usr/bin/env python3
"""Bind this generic build to exactly one generated, app-hosted test run."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def sources():
    return {"head": git("rev-parse", "HEAD"), "tree": git("rev-parse", "HEAD^{tree}"),
            "parent": git("rev-parse", "HEAD^"),
            "sources_tree": git("rev-parse", "HEAD:Sources"),
            "tests_tree": git("rev-parse", "HEAD:Tests"),
            "origin": git("remote", "get-url", "origin"),
            "tracked_status": git("status", "--porcelain=v1", "--untracked-files=no"),
            "files": {p: sha(Path(p)) for p in git("ls-files").splitlines()}}


def tree(path):
    files = {}
    for p in sorted(path.rglob("*")):
        if p.is_symlink():
            files[str(p.relative_to(path))] = {"symlink": str(p.readlink())}
        elif p.is_file():
            files[str(p.relative_to(path))] = {"bytes": p.stat().st_size, "sha256": sha(p)}
    if not files:
        raise ValueError(f"Missing/empty product resources: {path}")
    return files


def load(path):
    with path.open("rb") as handle:
        return plistlib.load(handle)


def select(products, arch, since_ns):
    candidates, rejected = [], {}
    for path in sorted(products.glob("*.xctestrun")):
        try:
            # Some CI/worktree volumes store only whole-second mtimes. Prior
            # specs were removed before this successful build; retain that
            # generation binding while rejecting older whole-second timestamps.
            if path.is_symlink() or path.stat().st_mtime_ns // 1_000_000_000 < since_ns // 1_000_000_000:
                raise ValueError("stale or symlinked specification")
            data = load(path)
            metadata = data.get("__xctestrun_metadata__", {})
            if metadata.get("FormatVersion") != 1:
                raise ValueError("unsupported generated format (expected observed format 1)")
            if metadata.get("ContainerInfo") != {"ContainerName": "HotMicPlayerTestHost", "SchemeName": "HotMicPlayerTests"}:
                raise ValueError("wrong container/scheme")
            if set(data) != {"__xctestrun_metadata__", "HotMicPlayerTests"}:
                raise ValueError("expected exactly the HotMicPlayerTests target")
            target = data["HotMicPlayerTests"]
            expected = {"BlueprintName": "HotMicPlayerTests", "BlueprintProviderName": "HotMicPlayerTestHost",
                        "ProductModuleName": "HotMicPlayerTests", "IsAppHostedTestBundle": True,
                        "TestHostBundleIdentifier": "com.hotmic.player.tests.host",
                        "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/HotMicPlayerTestHost.app",
                        "TestBundlePath": "__TESTHOST__/PlugIns/HotMicPlayerTests.xctest"}
            if any(target.get(k) != v for k, v in expected.items()):
                raise ValueError("incompatible app-hosted target identity or product paths")
            if target.get("SkipTestIdentifiers") or target.get("OnlyTestIdentifiers"):
                raise ValueError("generated specification restricts the original test target")
            app = products / target["TestHostPath"].removeprefix("__TESTROOT__/")
            bundle = app / target["TestBundlePath"].removeprefix("__TESTHOST__/")
            if app.resolve() != products / "Debug-iphonesimulator/HotMicPlayerTestHost.app" or bundle.resolve() != app / "PlugIns/HotMicPlayerTests.xctest":
                raise ValueError("products resolve outside this build")
            for product, identifier, executable in ((app, "com.hotmic.player.tests.host", "HotMicPlayerTestHost"),
                                                     (bundle, "com.hotmic.player.tests", "HotMicPlayerTests")):
                info = load(product / "Info.plist")
                if info.get("CFBundleIdentifier") != identifier or info.get("CFBundleExecutable") != executable or info.get("DTPlatformName") != "iphonesimulator":
                    raise ValueError(f"wrong simulator product identity: {product}")
                slices = subprocess.check_output(["xcrun", "lipo", "-archs", str(product / executable)], text=True).split()
                if slices != [arch]:
                    raise ValueError(f"expected native {arch} product, got {slices}: {product}")
            fixtures = tree(bundle / "Fixtures")
            if fixtures != tree(Path("Tests/HotMicPlayerTests/Fixtures")):
                raise ValueError("compiled Fixtures differ from original test resources")
            sdk = tree(bundle / "HotMicPlayer_HotMicPlayer.bundle")
            candidates.append((path, target, app, bundle, fixtures, sdk))
        except (OSError, ValueError, TypeError, KeyError, subprocess.CalledProcessError) as error:
            rejected[str(path)] = str(error)
    if len(candidates) != 1:
        raise ValueError(f"Expected exactly one current compatible xctestrun, found {len(candidates)}; rejected={rejected}")
    return candidates[0], rejected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "capture"))
    parser.add_argument("--derived", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), required=True)
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    products = args.derived.resolve() / "Build/Products"
    binding_path = evidence / "source-inputs.json"
    if args.phase == "prepare":
        # Cached binaries remain compatible (v3). Regenerate only specifications
        # so an older SDK/architecture or interrupted build cannot supply a run.
        previous = []
        for path in sorted(products.glob("*.xctestrun")):
            previous.append({"path": str(path), "sha256": sha(path)})
            path.unlink()
        binding = {"prepared_ns": time.time_ns(), "prepared_monotonic": time.monotonic(),
                   "products": str(products), "arch": args.arch, "source": sources(),
                   "previous_specifications": previous}
        binding_path.write_text(json.dumps(binding, indent=2) + "\n")
        return
    binding = json.loads(binding_path.read_text())
    build = json.loads((evidence / "simulator-build.json").read_text())
    if (binding["products"] != str(products) or binding["arch"] != args.arch or
            binding["source"] != sources() or build["exit_code"] != 0 or
            build["deadline"] - build["available_seconds"] < binding["prepared_monotonic"]):
        raise ValueError("Stale build/source/architecture binding or unsuccessful generic build")
    (path, target, app, bundle, fixtures, sdk), rejected = select(products, args.arch, binding["prepared_ns"])
    copied = evidence / "selected.xctestrun"
    shutil.copy2(path, copied)
    if sha(path) != sha(copied):
        raise ValueError("Copied specification hash mismatch")
    record = {"captured_ns": time.time_ns(), "captured_monotonic": time.monotonic(),
              "xctestrun": str(path), "xctestrun_sha256": sha(path), "evidence_copy": copied.name,
              "arch": args.arch, "target": target, "rejected": rejected, "source": binding["source"],
              "app": str(app), "test_bundle": str(bundle), "app_files": tree(app),
              "fixtures": fixtures, "sdk_resources": sdk}
    (evidence / "compiled-products.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"Validated compiled app-host test run: {path} (sha256={record['xctestrun_sha256']})")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Compiled test input validation failed: {error}")
