import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
output = root / '.tools/ios-ui'
output.mkdir(parents=True, exist_ok=True)
subprocess.run(['xcodegen', 'generate'], cwd=root / 'apple/ios-client', check=True)
runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '-j']))['runtimes']
runtime = next(item['identifier'] for item in reversed(runtimes) if item.get('isAvailable') and 'iOS' in item['name'])
types = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devicetypes', '-j']))['devicetypes']
for name, preferred in [('compact', ['iPhone 13 mini', 'iPhone SE (3rd generation)']), ('pro', ['iPhone 17 Pro', 'iPhone 16 Pro'])]:
    if len(sys.argv) > 1 and name != sys.argv[1]:
        continue
    device = next(item for title in preferred for item in types if item['name'] == title)
    udid = subprocess.check_output(['xcrun', 'simctl', 'create', f'SVOI-{name}', device['identifier'], runtime], text=True).strip()
    result = output / f'{name}.xcresult'
    print(f'Checking {name}: {device["name"]} on {runtime}', flush=True)
    try:
        subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True)
        subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True, timeout=180)
        subprocess.run(['xcrun', 'simctl', 'status_bar', udid, 'override', '--time', '9:41', '--batteryState', 'charged', '--batteryLevel', '100'], check=True)
        with (output / f'{name}.log').open('w') as log:
            test = subprocess.run(['xcodebuild', '-project', 'apple/ios-client/SVOI.xcodeproj', '-scheme', 'SVOIInterfacePreview',
                '-sdk', 'iphonesimulator', '-destination', f'platform=iOS Simulator,id={udid}',
                '-derivedDataPath', str(root / '.tools/ios-ui-build'), '-resultBundlePath', str(result),
                '-parallel-testing-enabled', 'NO', '-test-timeouts-enabled', 'YES',
                '-default-test-execution-time-allowance', '90', '-maximum-test-execution-time-allowance', '120',
                'CODE_SIGNING_ALLOWED=NO', 'test'], cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=600)
        if result.exists():
            subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result), '--output-path', str(output / name)], check=True)
        if test.returncode:
            print((output / f'{name}.log').read_text()[-20000:])
            raise SystemExit(test.returncode)
    finally:
        subprocess.run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(output / f'{name}-last-screen.png')], check=False)
        subprocess.run(['xcrun', 'simctl', 'shutdown', udid], check=False)
print('PASS: native iPhone UI, connection controls, import, profiles, themes, Dynamic Type, landscape')
