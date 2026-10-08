#!/usr/bin/env python3
"""Compare exact refill revisions using 10,000 real Factorio entities per pass."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import math
import shutil
import statistics
import subprocess
import tarfile
import time

REPO = Path(__file__).resolve().parents[1]
OLD = '8af5786eeb619b341df77e74effc4c4372705496'
NEW = '19f9953889f965cb59d9be0ba93a02866eb41b45'
SCENARIOS = ['full', 'active_10pct', 'mixed_half', 'partial', 'half', 'empty',
             'no_supply', 'depleted', 'dense', 'no_chest', 'mixed_supply', 'player_no_chest']
PREFIX = """local storage = {}
local settings = {global={['auto-loader-entities-per-tick']={value=10}}}
local noop = function() end
local tick_handler
local script = {on_init=noop,on_load=noop,on_configuration_changed=noop,
  on_event=function(event,handler) if event==defines.events.on_tick then tick_handler=handler end end,
  register_on_object_destroyed=function(entity) return entity.unit_number end}
"""
SUFFIX = """
return {tick=function() if tick_handler then tick_handler() end end,
  visits=function() return set_bucket_active and storage.active_consumer_count or #storage.order end,setup=function(entities,chests,budget)
  storage={fillables={},order={},cursor=1,reps={},representative_chests={},supply_candidates={},
    chest_buckets={},chest_records={},chest_destructions={},chest_count=0,
    consumer_buckets={},active_buckets={},bucket_cursor=1,traversal={bucket=1,consumer=1},active_consumer_count=0}
  tick_handler=on_tick
  settings.global['auto-loader-entities-per-tick'].value=budget
  build_caches()
  if restore_tick_handler then restore_tick_handler() end
  for _,chest in pairs(chests) do link_chest(chest) end
  for _,entity in ipairs(entities) do register_fillable(entity) end
end}
"""


def git(*args):
    return subprocess.check_output(['git', *args], cwd=REPO)


def find_factorio(explicit=None):
    # Prefer standalone macOS Factorio even when PATH contains a Steam copy.
    candidates = [explicit] if explicit else [
        '/Applications/factorio.app/Contents/MacOS/factorio', shutil.which('factorio')]
    return next((Path(p).resolve() for p in candidates if p and Path(p).is_file()), None)


def lua(value):
    if isinstance(value, dict):
        return '{'+','.join(f'[{json.dumps(k)}]={lua(v)}' for k, v in value.items())+'}'
    if isinstance(value, list):
        return '{'+','.join(map(lua, value))+'}'
    return json.dumps(value)


def copy_revision(rev, target):
    if isinstance(rev, Path):
        shutil.copytree(rev, target)
        return
    target.mkdir(parents=True)
    if rev == 'WORKTREE':
        for name in ['info.json','control.lua','data.lua','settings.lua']:
            shutil.copy2(REPO/name, target/name)
        for name in ['graphics','locale']:
            shutil.copytree(REPO/name, target/name)
        return
    with tarfile.open(fileobj=io.BytesIO(git('archive', rev))) as archive:
        for member in archive.getmembers():
            if member.name in ['info.json','control.lua','data.lua','settings.lua'] or member.name.startswith(('graphics/','locale/')):
                if member.isfile():
                    if Path(member.name).is_absolute() or '..' in Path(member.name).parts:
                        raise ValueError('Unsafe archive path')
                    destination = target/member.name
                    destination.parent.mkdir(parents=True,exist_ok=True)
                    destination.write_bytes(archive.extractfile(member).read())


def run(command, logfile, timeout):
    print(f'Running {logfile.name}', flush=True)
    start = time.monotonic()
    with logfile.open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT,
                       check=True, timeout=timeout)
    print(f'Finished {logfile.name} in {time.monotonic()-start:.1f}s', flush=True)


def summarize(root, config):
    log = (root/'callback.log').read_text()
    assert 'BENCH SUCCESS' in log and '\nDone.' in log, 'Incomplete callback run'
    pattern = r'BENCH (\d+) (\d+) (\S+) (old|new) (\d+) (\d+) (\d+) Duration: ([\d.]+)ms'
    rows = [dict(sample=int(s),budget=int(b),scenario=c,version=v,iteration=int(i),
                 transferred=int(t),callbacks=int(calls),sweep_ms=float(ms))
            for s,b,c,v,i,t,calls,ms in re.findall(pattern, log)]
    assert len(rows)==config['samples']*len(config['budgets'])*len(config['scenarios'])*2*config['iterations']
    (root/'callback-results.json').write_text(json.dumps(rows, indent=2)+'\n')
    lines = ['| Budget | Scenario | Old sweep ms | New sweep ms | Change | Old ms/callback | New ms/callback |',
             '|---:|---|---:|---:|---:|---:|---:|']
    summary = []
    for budget in config['budgets']:
        for scenario in config['scenarios']:
            values = {}
            sample_means = {}
            for version in ['old','new']:
                samples = [statistics.mean(r['sweep_ms'] for r in rows if r['budget']==budget and
                    r['scenario']==scenario and r['version']==version and r['sample']==sample)
                    for sample in range(1,config['samples']+1)]
                values[version] = statistics.median(samples)
                sample_means[version] = samples
            summary.append(dict(budget=budget,scenario=scenario,sample_mean_sweep_ms=sample_means,
                median_sweep_ms=values,paired_change_percent=[(n/o-1)*100
                    for o,n in zip(sample_means['old'],sample_means['new'])]))
            old,new = values['old'],values['new']
            calls = {v:next(r['callbacks'] for r in rows if r['budget']==budget and
                     r['scenario']==scenario and r['version']==v) for v in ['old','new']}
            lines.append(f"| {budget} | {scenario} | {old:.3f} | {new:.3f} | {(new/old-1)*100:+.1f}% | {old/calls['old']:.4f} | {new/calls['new']:.4f} |")
    (root/'callback-results.md').write_text('\n'.join(lines)+'\n')
    (root/'callback-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('\n'.join(lines))


def prepare_player_save(command, mods, save, root, logfile, timeout):
    """Create an actual LuaPlayer in a separate client, then benchmark its save."""
    saves = root/'user/saves'
    previous = {p: p.stat().st_mtime_ns for p in saves.glob('*benchmark-player*.zip')}
    with logfile.open('w') as output:
        process = subprocess.Popen(command+['--mod-directory',str(mods),'--load-game',str(save),
            '--disable-audio','--window-size','800x600','--disable-migration-window',
            '--force-graphics-preset','very-low'], stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic()+timeout
            while time.monotonic()<deadline:
                ready = [p for p in saves.glob('*benchmark-player*.zip')
                         if p.stat().st_mtime_ns != previous.get(p)]
                # Factorio writes .tmp first and renames the completed archive.
                if ready:
                    shutil.copy2(max(ready,key=lambda p:p.stat().st_mtime_ns), save)
                    return
                if process.poll() is not None:
                    raise RuntimeError(f'Player fixture exited before saving; inspect {logfile}')
                time.sleep(0.1)
            raise RuntimeError(f'Player fixture timed out; inspect {logfile}')
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def production(args,root,config,revisions,info,builtins,command):
    if any(s not in ['full','partial','half','empty','mixed_half','active_10pct','no_supply','no_chest','mixed_supply','player_no_chest'] for s in config['scenarios']):
        raise ValueError('Production mode does not support depleted or dense scenarios')
    for budget in config['budgets']:
        for scenario in config['scenarios']:
            case = root/f'{budget}-{scenario}'
            case.mkdir()
            entities = 1 if scenario == 'player_no_chest' else args.entities
            case_budget = min(budget, entities)
            actual_ticks = max(args.ticks,12*entities//case_budget)
            case_config = dict(config,entities=entities,budget=case_budget,scenario=scenario,actual_ticks=actual_ticks)
            for label,rev in revisions.items():
                mods = case/label
                revision_info = json.loads((rev / "info.json").read_text())
                copy_revision(rev,mods/f"{revision_info['name']}_{revision_info['version']}")
                fixture = mods/'refill-benchmark_0.1.0'
                fixture.mkdir()
                (fixture/'info.json').write_text(json.dumps(dict(name='refill-benchmark',version='0.1.0',
                    title='Refill benchmark fixture',author='Auto-Loader',factorio_version=info['factorio_version'],
                    dependencies=[info['name']])))
                for source,dest in [('fixture.lua','fixture.lua'),('production.lua','control.lua')]:
                    shutil.copy2(REPO/'benchmarks/factorio'/source,fixture/dest)
                version_config = dict(case_config, supplied_queue='storage.consumer_buckets' in (rev/'control.lua').read_text())
                (fixture/'config.lua').write_text('return '+lua(version_config)+'\n')
                (fixture/'settings-final-fixes.lua').write_text(
                    f"data.raw['int-setting']['auto-loader-entities-per-tick'].default_value = {case_budget}\n")
                (mods/'mod-list.json').write_text(json.dumps({'mods':[dict(name=n,enabled=True)
                    for n in builtins+[info['name'],'refill-benchmark']]},indent=2))
                run(command+['--mod-directory',str(mods),'--create',str(case/f'{label}.zip'),
                    '--map-gen-settings',str(root/'map.json')],case/f'create-{label}.log',args.timeout)
                if scenario == 'player_no_chest':
                    prepare_player_save(command,mods,case/f'{label}.zip',root,case/f'player-{label}.log',args.timeout)
            for sample in range(1,args.samples+1):
                for label in (['old','new'] if sample%2 else ['new','old']):
                    logfile = case/f'{sample}-{label}.log'
                    run(command+['--mod-directory',str(case/label),'--benchmark',str(case/f'{label}.zip'),
                        '--benchmark-ticks',str(actual_ticks),'--benchmark-runs','1',
                        '--benchmark-verbose','all'],logfile,args.timeout)
                    log = logfile.read_text()
                    if 'PRODUCTION SUCCESS' not in log:
                        raise RuntimeError(f'Incomplete production validation: {logfile}')
    summarize_production(root,config)


def percentile(values, fraction):
    return sorted(values)[max(0,math.ceil(len(values)*fraction)-1)]


def summarize_production(root,config):
    results = []
    for budget in config['budgets']:
        for scenario in config['scenarios']:
            for sample in range(1,config['samples']+1):
                for version in ['old','new']:
                    logfile = root/f'{budget}-{scenario}'/f'{sample}-{version}.log'
                    log = logfile.read_text()
                    assert 'PRODUCTION SUCCESS' in log
                    header = next(line.split(',') for line in log.splitlines() if line.startswith('tick,'))
                    ticks = [dict(zip(header,line.split(','))) for line in log.splitlines()
                             if re.match(r'^t\d+,',line)]
                    entities = 1 if scenario == 'player_no_chest' else config['entities']
                    actual_ticks = max(config['ticks'],12*entities//min(budget,entities))
                    assert len(ticks)==actual_ticks
                    total = sum(int(t['wholeUpdate']) for t in ticks)/1e6
                    reported = float(re.search(r'updates in ([\d.]+) ms',log).group(1))
                    # The outer benchmark timer also includes dispatch overhead.
                    assert abs(total/reported-1)<0.01, 'Verbose timing units or parsing mismatch'
                    # Drop two complete sweeps or 60 ticks, whichever is longer.
                    warmup = max(60,2*entities//min(budget,entities))
                    ticks = ticks[warmup:]
                    assert ticks, 'No samples after warmup'
                    row = dict(budget=budget,scenario=scenario,sample=sample,version=version,
                               ticks=actual_ticks,warmup_ticks=warmup,measured_ticks=len(ticks))
                    for key in ['wholeUpdate','scriptUpdate','luaGarbageIncremental']:
                        values = [int(t[key])/1e6 for t in ticks]
                        row[key] = dict(mean_ms=statistics.mean(values),p50_ms=statistics.median(values),
                            p95_ms=percentile(values,.95),p99_ms=percentile(values,.99),max_ms=max(values))
                    results.append(row)
    (root/'production-results.json').write_text(json.dumps(results,indent=2)+'\n')
    lines = ['| Budget | Scenario | Old update ms | New update ms | Change | Old p99 ms | New p99 ms |',
             '|---:|---|---:|---:|---:|---:|---:|']
    for budget in config['budgets']:
        for scenario in config['scenarios']:
            groups = {v:[r for r in results if r['budget']==budget and r['scenario']==scenario
                         and r['version']==v] for v in ['old','new']}
            old,new = [statistics.median(r['wholeUpdate']['mean_ms'] for r in groups[v]) for v in ['old','new']]
            po,pn = [statistics.median(r['wholeUpdate']['p99_ms'] for r in groups[v]) for v in ['old','new']]
            lines.append(f'| {budget} | {scenario} | {old:.3f} | {new:.3f} | {(new/old-1)*100:+.1f}% | {po:.3f} | {pn:.3f} |')
    (root/'production-results.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--factorio', default=os.environ.get('AUTO_FACTORIO'),
                        help='Executable (default: /Applications/factorio.app, then PATH; AUTO_FACTORIO overrides)')
    parser.add_argument('--data', default=os.environ.get('AUTO_FACTORIO_DATA'))
    parser.add_argument('--old', default=OLD, help='Git revision, source snapshot directory, or WORKTREE')
    parser.add_argument('--new', default=NEW, help='Git revision, source snapshot directory, or WORKTREE')
    parser.add_argument('--entities', type=int, default=10000, help='Fixed fixture size: 10000')
    parser.add_argument('--chests-per-bucket', type=int, default=1, choices=range(1,1001), metavar='1..1000')
    parser.add_argument('--samples', type=int, default=6)
    parser.add_argument('--iterations', type=int, default=4)
    parser.add_argument('--budgets', type=int, nargs='+', default=[10,100,1000,10000])
    parser.add_argument('--scenarios', nargs='+', choices=SCENARIOS)
    parser.add_argument('--timeout', type=float, default=1800)
    parser.add_argument('--mode', choices=['callback','production'], default='callback')
    parser.add_argument('--ticks', type=int, default=120,
                        help='Minimum production ticks; raised to cover 12 complete sweeps (default: 120)')
    args = parser.parse_args()
    if args.entities!=10000 or any(b<1 or b>10000 or args.entities%b for b in args.budgets):
        parser.error('This fixture uses exactly 10,000 entities; budgets must divide 10,000 and be in 1..10,000')
    if args.scenarios is None:
        args.scenarios = ['full','partial','empty'] if args.mode=='production' else SCENARIOS[:-3]
    if args.mode == 'callback':
        if any(s in ['no_chest','player_no_chest'] for s in args.scenarios):
            parser.error('No-chest scenarios require production mode to measure event scheduling')
        if 'mixed_supply' in args.scenarios and args.scenarios != ['mixed_supply']:
            parser.error('Callback mixed_supply requires its own run because it changes world topology')
    if args.samples<1 or args.iterations<1:
        parser.error('Samples and iterations must be positive')
    executable = find_factorio(args.factorio)
    if not executable:
        parser.error('Factorio not found; use --factorio')
    data = Path(args.data).resolve() if args.data else next((p for p in
        [executable.parent.parent/'data',executable.parent.parent.parent/'data'] if (p/'base/info.json').is_file()),None)
    if not data:
        parser.error('Data not found; use --data')
    root = args.output.resolve()
    root.mkdir(parents=True,exist_ok=False)
    (root/'user').mkdir()
    shutil.copy2(Path(__file__),root/'runner-snapshot.py')
    config = dict(entities=args.entities,samples=args.samples,iterations=args.iterations,
                  budgets=args.budgets,scenarios=args.scenarios,ticks=args.ticks,
                  chests_per_bucket=args.chests_per_bucket)
    if args.mode == 'callback' and args.scenarios == ['mixed_supply']:
        config['scenario'] = 'mixed_supply'
    revisions = {label:rev if rev=='WORKTREE' else (Path(rev).resolve() if Path(rev).is_dir()
                 else git('rev-parse',rev).decode().strip())
                 for label,rev in [('old',args.old),('new',args.new)]}
    snapshots = {}
    for label,rev in revisions.items():
        snapshots[label] = root/'sources'/label
        copy_revision(rev,snapshots[label])
    info = json.loads((snapshots['new']/'info.json').read_text())
    builtins = sorted(json.loads(p.read_text())['name'] for p in data.glob('*/info.json') if p.parent.name!='core')
    metadata = dict(config=config,revisions={label:str(rev) for label,rev in revisions.items()},
                    sha256={},builtins=builtins,
                    executable=str(executable),data=str(data),
                    factorio_version=subprocess.check_output([str(executable),'--version'],text=True),
                    created_at=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
    if 'WORKTREE' in revisions.values():
        metadata['worktree_head'] = git('rev-parse','HEAD').decode().strip()
    metadata['source_sha256'] = {label:{str(p.relative_to(snapshot)):hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(snapshot.rglob('*')) if p.is_file()} for label,snapshot in snapshots.items()}
    for label,rev in revisions.items():
        source = (snapshots[label]/'control.lua').read_bytes()
        (root/f'{label}-control.lua').write_bytes(source)
        metadata['sha256'][label]=hashlib.sha256(source).hexdigest()
    for name in ['data.lua','settings.lua']:
        sources = [(snapshots[label]/name).read_text() for label in ['old','new']]
        if name == 'settings.lua':
            # This fixture has no players. Allow only the known per-player delay
            # addition; retain the guard against any benchmark-relevant changes.
            player_delay = '''  {
    type = "int-setting",
    name = "auto-loader-player-ammo-refill-delay",
    setting_type = "runtime-per-user",
    default_value = 10,
    minimum_value = 0,
    maximum_value = 3600,
    order = "a",
  },
'''
            if sources[0] != sources[1]:
                metadata['settings_difference'] = 'Allowed player ammo delay setting; fixture has no players'
            sources = [source.replace(player_delay,'') for source in sources]
        if sources[0] != sources[1]:
            raise RuntimeError(f'{name} differs; shared callback prototypes would not be equivalent')
    (root/'sources.json').write_text(json.dumps(metadata,indent=2)+'\n')
    (root/'config.ini').write_text(f'[path]\nread-data={data}\nwrite-data={root}/user\n[general]\ncheck-updates=false\n')
    (root/'map.json').write_text(json.dumps(dict(width=416,height=416,seed=42,
        default_enable_all_autoplace_controls=False,autoplace_controls={},
        autoplace_settings={k:dict(treat_missing_as_default=False) for k in ['entity','tile','decorative']})))
    command = [str(executable),'--config',str(root/'config.ini')]
    if args.mode=='callback':
        mods = root/'mods'
        mod = mods/f"{info['name']}_{info['version']}"
        copy_revision(snapshots['new'],mod)
        for label in revisions:
            (mod/f'{label}.lua').write_text(PREFIX+(root/f'{label}-control.lua').read_text()+SUFFIX)
        for source,dest in [('fixture.lua','fixture.lua'),('callback.lua','control.lua')]:
            shutil.copy2(REPO/'benchmarks/factorio'/source,mod/dest)
        (mod/'config.lua').write_text('return '+lua(config)+'\n')
        (mods/'mod-list.json').write_text(json.dumps({'mods':[dict(name=n,enabled=True) for n in builtins+[info['name']]]},indent=2))
        run(command+['--mod-directory',str(mods),'--create',str(root/'callback.zip'),
            '--map-gen-settings',str(root/'map.json')],root/'callback.log',args.timeout)
        summarize(root,config)
    else:
        production(args,root,config,snapshots,info,builtins,command)


if __name__=='__main__':
    main()
