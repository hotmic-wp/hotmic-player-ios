#!/usr/bin/env python3
"""Package built device products for Device Farm; never builds, signs or uploads."""
import argparse
import pathlib
import plistlib
import zipfile


def zip_tree(path, output, prefix):
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(path.rglob('*')):
            if file.is_file():
                archive.write(file, prefix + str(file.relative_to(path)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--products', required=True, help='Build/Products/<Configuration>-iphoneos')
    parser.add_argument('--app', required=True, help='App product name, without .app')
    parser.add_argument('--tests', required=True, help='UI-test target name, without -Runner.app')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    products = pathlib.Path(args.products)
    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    app = products / f'{args.app}.app'
    runner = products / f'{args.tests}-Runner.app'
    for bundle in (app, runner):
        info_path = bundle / 'Info.plist'
        if not info_path.exists():
            raise SystemExit(f'Missing device bundle: {bundle}')
        if plistlib.loads(info_path.read_bytes()).get('DTPlatformName') != 'iphoneos':
            raise SystemExit(f'Not an iOS device bundle: {bundle}')
    # Device Farm takes the app as an IPA and the UI runner as a ZIP with the runner app at its root.
    zip_tree(app, output / f'{args.app}.ipa', prefix=f'Payload/{app.name}/')
    zip_tree(runner, output / f'{args.tests}.zip', prefix=f'{runner.name}/')
    (output / 'README.txt').write_text(
        f'Device Farm: upload {args.app}.ipa as IOS_APP and {args.tests}.zip as XCTEST_UI_TEST_PACKAGE.\n'
        'Both are unsigned; Device Farm re-signs them for its public devices. They cannot be installed '
        'directly on an owned iPhone.\n')
    print(output)


if __name__ == '__main__':
    main()
