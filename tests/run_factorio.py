#!/usr/bin/env python3
"""Run integration tests against the working mod in an isolated Factorio directory."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


REPO = Path(__file__).resolve().parents[1]


def find_factorio(explicit=None):
    # Prefer standalone macOS Factorio even when PATH contains a Steam copy.
    candidates = [explicit] if explicit else [
        '/Applications/factorio.app/Contents/MacOS/factorio', shutil.which('factorio')]
    return next((Path(p).resolve() for p in candidates if p and Path(p).is_file()), None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test', choices=['player_ammo','supply'], default='player_ammo')
    parser.add_argument('--factorio', default=os.environ.get('AUTO_FACTORIO'),
                        help='Executable (default: /Applications/factorio.app, then PATH; AUTO_FACTORIO overrides)')
    parser.add_argument('--data', default=os.environ.get('AUTO_FACTORIO_DATA'),
                        help='Factorio data directory (or AUTO_FACTORIO_DATA)')
    parser.add_argument('--timeout', type=float, default=120,
                        help='Timeout in seconds per launch (default: 120)')
    args = parser.parse_args()
    executable = find_factorio(args.factorio)
    if not executable:
        parser.error('Factorio not found; pass --factorio or set AUTO_FACTORIO')
    data_candidates = [executable.parent.parent / 'data', executable.parent.parent.parent / 'data']
    data = Path(args.data).resolve() if args.data else next(
        (p for p in data_candidates if (p / 'base/info.json').is_file()), data_candidates[0])
    if not (data / 'base/info.json').is_file():
        parser.error('Data directory not found; pass --data or set AUTO_FACTORIO_DATA')
    root = Path(tempfile.mkdtemp(prefix='auto-loader-test-'))
    print(f'Test workspace and logs: {root}', flush=True)
    (root / 'user').mkdir()
    info = json.loads((REPO / 'info.json').read_text())
    mod = root / 'mods' / f"{info['name']}_{info['version']}"
    mod.mkdir(parents=True)
    for name in ['info.json', 'control.lua', 'data.lua', 'settings.lua']:
        shutil.copy2(REPO / name, mod / name)
    for name in ['graphics', 'locale']:
        shutil.copytree(REPO / name, mod / name)
    fixture_name = 'auto-loader-test'
    fixture = root / 'mods' / f'{fixture_name}_0.1.0'
    fixture.mkdir()
    (fixture / 'info.json').write_text(json.dumps({
        'name': fixture_name, 'version': '0.1.0', 'title': 'Auto-Loader integration test',
        'author': 'Auto-Loader', 'factorio_version': info['factorio_version'],
        'dependencies': [info['name']],
    }))
    shutil.copy2(REPO / 'tests/factorio' / f'{args.test}.lua', fixture / 'control.lua')
    (fixture / 'settings-final-fixes.lua').write_text(
        "data.raw['int-setting']['auto-loader-player-ammo-refill-delay'].default_value = 1\n"
        + ("data.raw['int-setting']['auto-loader-entities-per-tick'].default_value = 100\n"
           if args.test == 'supply' else ''))
    if args.test == 'supply':
        (fixture / 'data-final-fixes.lua').write_text(
            "local turret = table.deepcopy(data.raw['ammo-turret']['gun-turret'])\n"
            "turret.name = 'auto-loader-test-turret'\n"
            "turret.automated_ammo_count = 120\n"
            "data:extend{turret}\n")
    builtins = sorted(json.loads(p.read_text())['name']
                      for p in data.glob('*/info.json') if p.parent.name != 'core')
    (root / 'mods/mod-list.json').write_text(json.dumps({
        'mods': [{'name': name, 'enabled': True}
                 for name in builtins + [info['name'], fixture_name]],
    }))
    (root / 'config.ini').write_text(
        f'[path]\nread-data={data}\nwrite-data={root}/user\n'
        '[general]\ncheck-updates=false\n'
        '[other]\nshow-tips-and-tricks=false\n')
    command = [str(executable), '--config', str(root / 'config.ini'),
               '--mod-directory', str(root / 'mods')]
    with (root / 'create.log').open('w') as output:
        subprocess.run(command + ['--create', str(root / 'test.zip')],
                       stdout=output, stderr=subprocess.STDOUT, check=True, timeout=args.timeout)
    if args.test == 'supply':
        with (root / 'test.log').open('w') as output:
            subprocess.run(command + ['--benchmark',str(root/'test.zip'),
                '--benchmark-ticks','3','--benchmark-runs','1'], stdout=output,
                stderr=subprocess.STDOUT, check=True, timeout=args.timeout)
        log = (root/'test.log').read_text()
        if 'AUTO_LOADER_TEST SUCCESS' not in log:
            raise RuntimeError(f'Factorio supply test incomplete; inspect {root}/test.log')
        print('\n'.join(line for line in log.splitlines() if 'AUTO_LOADER_TEST' in line))
        return 0
    # Loading a single-player game creates the real LuaPlayer needed for cursor_stack.
    with (root / 'test.log').open('w') as output:
        process = subprocess.Popen(command + [
            '--load-game', str(root / 'test.zip'), '--disable-audio',
            '--window-size', '800x600', '--disable-migration-window',
            '--force-graphics-preset', 'very-low',
        ], stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline:
                log = (root / 'test.log').read_text(errors='replace')
                if 'AUTO_LOADER_TEST SUCCESS' in log:
                    print('\n'.join(line for line in log.splitlines() if 'AUTO_LOADER_TEST' in line))
                    return 0
                if ('AUTO_LOADER_TEST FAIL:' in log or 'Error while running' in log
                        or 'Received SIG' in log or 'Factorio crashed' in log
                        or process.poll() is not None):
                    raise RuntimeError(f'Factorio test failed; inspect {root}/test.log')
                time.sleep(0.1)
            raise RuntimeError(f'Factorio test timed out; inspect {root}/test.log')
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
