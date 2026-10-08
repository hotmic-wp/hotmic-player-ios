#!/usr/bin/env python3
"""Package existing device products; never builds, signs, uploads or deploys."""
import argparse,json,pathlib,plistlib,shutil,sys,zipfile

def zip_tree(path,output,prefix=''):
    with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as z:
        for file in sorted(path.rglob('*')):
            if file.is_file(): z.write(file,prefix+str(file.relative_to(path)))

def main():
    p=argparse.ArgumentParser(); p.add_argument('--products',required=True); p.add_argument('--output',required=True); p.add_argument('--grid-url'); a=p.parse_args()
    products=pathlib.Path(a.products); out=pathlib.Path(a.output); out.mkdir(parents=True,exist_ok=True)
    app=products/'HotMicPlayerDemo.app'; runner=products/'HotMicPlayerDemoUITests-Runner.app'
    for bundle in [app,runner]:
        if not (bundle/'Info.plist').exists(): raise SystemExit(f'Missing device bundle: {bundle}')
        info=plistlib.loads((bundle/'Info.plist').read_bytes())
        if info.get('DTPlatformName')!='iphoneos': raise SystemExit(f'Not an iOS device bundle: {bundle}')
    # grid-url.txt is a resource in the XCTest bundle, before optional signing.
    if a.grid_url:
        resource=runner/'PlugIns/HotMicPlayerDemoUITests.xctest/grid-url.txt'
        resource.write_text(a.grid_url+'\n')
    zip_tree(app,out/'HotMicPlayerDemo.ipa',prefix='Payload/HotMicPlayerDemo.app/')
    zip_tree(runner,out/'HotMicPlayerDemoUITests.zip',prefix=runner.name+'/')
    (out/'README.txt').write_text('Device Farm: upload HotMicPlayerDemo.ipa as IOS_APP and HotMicPlayerDemoUITests.zip as XCTEST_UI_TEST_PACKAGE. This package has no Payload directory. Unsigned builds need Device Farm public-device re-signing; they cannot install directly on an owned iPhone.\n')
    print(out)
if __name__=='__main__': main()
