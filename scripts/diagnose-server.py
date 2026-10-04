"""Temporary focused CI experiment; never used to seed or gate UI readiness."""

import json
import os
from pathlib import Path
import re
import subprocess
import time
from urllib.request import urlopen

root = Path(os.environ['RUNNER_TEMP'])
output = root / 'server-latency'
output.mkdir()
log = (root / 'screenshot-server/logs/supervisord.log').read_text()
pid = int(re.findall(r"spawned: 'worker_daphne' with pid (\d+)", log)[-1])
base = os.environ['ARCHIVEBOX_TEST_SERVER']
failures = []


def measure(phase):
    print(f'PHASE {phase}', flush=True)
    # The app cancels discovery when URL editing finishes. Exercise that real
    # HTTP cancellation before the first full request, while server pages are cold.
    start = time.monotonic()
    try:
        with urlopen(base + '/api/v1/openapi.json', timeout=0.2) as response:
            response.read()
        result = 'completed'
    except TimeoutError:
        result = 'cancelled'
    print(json.dumps(dict(phase=phase, cancellation=result, seconds=time.monotonic() - start)), flush=True)
    # A fixed measurement batch, not a retry/readiness loop. Every response is
    # validated and every timeout remains a failure after all phases finish.
    for sample in range(3):
        for path in ('/api/v1/openapi.json', '/health/'):
            start = time.monotonic()
            try:
                with urlopen(base + path, timeout=15) as response:
                    body = response.read()
                    assert response.status == 200
                    if path == '/health/':
                        assert body == b'OK'
                    else:
                        assert 'archivebox' in json.loads(body)['info']['title'].lower()
                result = 'ok'
            except Exception as error:
                result = f'{type(error).__name__}: {error}'
                failures.append((phase, path, result))
            print(json.dumps(dict(phase=phase, sample=sample, path=path,
                                  seconds=time.monotonic() - start, result=result)), flush=True)
    # Collect only after measuring: procinfo itself took 50s under boot pressure
    # and otherwise moved the request away from the period being investigated.
    subprocess.run(['ps', '-p', str(pid), '-o', 'pid,stat,pri,nice,time,rss,comm'])
    subprocess.run(['vm_stat'])
    with (output / f'{phase}-memory.txt').open('w') as stream:
        subprocess.run(['ps', '-A', '-o', 'pid,ppid,rss,comm'], stdout=stream)


measure('before-boot')
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
runtimes = sorted((key for key in devices if 'iOS-26' in key), reverse=True)
device = next(d for runtime in runtimes for d in devices[runtime] if d['name'].startswith('iPhone'))
subprocess.run(['xcrun', 'simctl', 'bootstatus', device['udid'], '-b'], check=True)
measure('after-boot')
with (output / 'profiler.log').open('w') as stream:
    profile = subprocess.Popen(['sudo', '-n', 'py-spy', 'record', '--pid', str(pid),
                                '--duration', '60', '--rate', '10', '--format', 'speedscope',
                                '--idle', '--threads', '--nonblocking',
                                '--output', str(output / 'profile.json')], stdout=stream, stderr=stream)
    measure('with-profiler')
    profile.wait()
measure('after-profiler')
assert not failures, failures
