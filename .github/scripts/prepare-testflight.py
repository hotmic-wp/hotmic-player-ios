#!/usr/bin/env python3
"""Prepare a TestFlight archive of one Sample app target; never builds, signs or uploads.

check-profile: validate a decoded App Store profile (`security cms -D` output) against the
team, bundle id and the signing identity's SHA-1, and print NAME=value lines for $GITHUB_ENV.
pin-signing: switch only that target's Release configuration to manual distribution signing
(command-line overrides would also reach the package's resource bundle, which rejects a
profile), point it at an extra Info.plist, and write the export options.
"""
import argparse
import hashlib
import pathlib
import plistlib
import re
import sys


def fail(message):
    print(f'::error title=TestFlight signing::{message}')
    sys.exit(1)


def check_profile(args):
    profile = plistlib.loads(pathlib.Path(args.profile_plist).read_bytes())
    expected_app_id = f'{args.team}.{args.bundle_id}'
    app_id = profile.get('Entitlements', {}).get('application-identifier')
    if app_id != expected_app_id:
        fail(f'the provisioning profile is for {app_id}, not {expected_app_id}')
    if args.team not in profile.get('TeamIdentifier', []):
        fail('the provisioning profile belongs to another team than APPLE_TEAM_ID')
    if profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices'):
        fail('the provisioning profile is Development/Ad Hoc/Enterprise; TestFlight needs an App Store Connect profile')
    if profile.get('Entitlements', {}).get('get-task-allow'):
        fail('the provisioning profile allows debugging (get-task-allow); it is not a distribution profile')
    certificates = {hashlib.sha1(der).hexdigest().upper() for der in profile.get('DeveloperCertificates', [])}
    identities = {sha.upper() for sha in args.identity_sha1}
    if not certificates & identities:
        fail('the provisioning profile does not include the certificate in IOS_DIST_P12_BASE64; '
             'regenerate the profile with that certificate selected')
    print(f"PROFILE_NAME={profile['Name']}")
    print(f"PROFILE_UUID={profile['UUID']}")
    print(f"PROFILE_EXPIRES={profile['ExpirationDate']:%Y-%m-%d}")


def pin_signing(args):
    project = pathlib.Path(args.project) / 'project.pbxproj'
    with open(project, encoding='utf-8', newline='') as file:
        text = file.read()
    block = re.compile(
        r'(/\* Release \*/ = \{\s*isa = XCBuildConfiguration;\s*buildSettings = \{)(.*?)(\n\s*\};\s*name = Release;)',
        re.S)
    marker = f'PRODUCT_BUNDLE_IDENTIFIER = {args.bundle_id};'
    hits = [m for m in block.finditer(text) if marker in m.group(2)]
    if len(hits) != 1:
        fail(f'expected one Release configuration with {marker}, found {len(hits)}')
    match = hits[0]
    body = re.sub(r'\n\s*(CODE_SIGN_STYLE|CODE_SIGN_IDENTITY|DEVELOPMENT_TEAM|PROVISIONING_PROFILE_SPECIFIER'
                  r'|INFOPLIST_FILE|CURRENT_PROJECT_VERSION) = [^;\n]*;', '', match.group(2))
    pinned = {
        'CODE_SIGN_STYLE': 'Manual',
        'CODE_SIGN_IDENTITY': '"Apple Distribution"',
        'DEVELOPMENT_TEAM': args.team,
        'PROVISIONING_PROFILE_SPECIFIER': f'"{args.profile_name}"',
        'INFOPLIST_FILE': f'"{args.info_plist}"',
        'CURRENT_PROJECT_VERSION': args.build_number,
    }
    body += ''.join(f'\n\t\t\t\t{key} = {value};' for key, value in pinned.items())
    with open(project, 'w', encoding='utf-8', newline='') as file:
        file.write(text[:match.start(2)] + body + text[match.end(2):])

    # Merged into the generated Info.plist, as Debug-Info.plist is for Debug.
    info = {'HMBuildSHA': args.build_sha, 'ITSAppUsesNonExemptEncryption': False}
    (pathlib.Path(args.project).parent / args.info_plist).write_bytes(plistlib.dumps(info))
    options = {
        'method': 'app-store-connect',
        'destination': 'export',
        'teamID': args.team,
        'signingStyle': 'manual',
        'signingCertificate': 'Apple Distribution',
        'provisioningProfiles': {args.bundle_id: args.profile_name},
        'uploadSymbols': True,
        'manageAppVersionAndBuildNumber': False,
    }
    pathlib.Path(args.export_options).write_bytes(plistlib.dumps(options))
    print(project)


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('check-profile')
    check.add_argument('--profile-plist', required=True)
    check.add_argument('--team', required=True)
    check.add_argument('--bundle-id', required=True)
    check.add_argument('--identity-sha1', action='append', required=True)
    pin = commands.add_parser('pin-signing')
    pin.add_argument('--project', required=True, help='path to the .xcodeproj')
    pin.add_argument('--bundle-id', required=True)
    pin.add_argument('--team', required=True)
    pin.add_argument('--profile-name', required=True)
    pin.add_argument('--build-number', required=True)
    pin.add_argument('--build-sha', required=True)
    pin.add_argument('--info-plist', required=True, help='file name, written next to the .xcodeproj')
    pin.add_argument('--export-options', required=True)
    args = parser.parse_args()
    {'check-profile': check_profile, 'pin-signing': pin_signing}[args.command](args)


if __name__ == '__main__':
    main()
