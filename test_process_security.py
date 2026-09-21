#!/usr/bin/env python3
"""Run the panel's real process logic in Quickshell inside a mount namespace.

Only the desktop commands are replaced. No test changes the live temperature,
daemon, or state file. Requires Quickshell and bubblewrap.
"""

import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile


REPO = Path(__file__).resolve().parent


def exercise(directory, missing=False):
    panel = (REPO / "Panel.qml").read_text()
    logic = panel.split("Panel {", 1)[1].split("  implicitWidth:", 1)[0]
    logic = logic.replace('  moduleName:', '  property string moduleName:')
    logic = logic.replace('  ipcTarget:', '  property string ipcTarget:')
    logic = logic.replace('  manageIpc:', '  property bool manageIpc:')
    processes = panel.split('  // Open, validate, and read through one descriptor.', 1)[1]
    processes = processes.split('\n', 1)[1].split('  // Probing keeps', 1)[0]
    processes = processes.replace('id: applyProcess', 'id: applyProcess; stderr: StdioCollector { onStreamFinished: console.log(text) }')
    script = '''
import QtQuick
import Quickshell
import Quickshell.Io
import "TemperatureSteps.js" as Steps
ShellRoot {
''' + logic + processes + '''
  property int stage: 0
  Timer {
    interval: 50; running: true; repeat: true
    onTriggered: {
      if (!root.loaded || stateWriter.running || probeProcess.running ||
          nightlightRefresh.running || applyProcess.running) return
      if (root.stage === 0) {
        if (root.warmTemperature !== 3500 || !root.active) throw Error("state read failed")
        root.saveTemperature(4000)
      } else if (root.stage === 1) {
        if (root.applyFailed !== EXPECT_FAILURE) throw Error("wrong apply result")
        root.probe()
      } else if (root.stage === 2) {
        nightlightRefresh.running = true
      } else {
        console.log("PROCESS_TEST_PASS")
        Qt.quit()
      }
      root.stage++
    }
  }
}
'''
    script = script.replace('EXPECT_FAILURE', str(missing).lower())
    (directory / 'shell.qml').write_text(script)
    for name in ('TemperatureSteps.js', 'state_file.py'):
        shutil.copy2(REPO / name, directory / name)
    runtime = directory / 'runtime'
    runtime.mkdir(mode=0o700)
    home = directory / 'home'
    state = home / '.config/omarchy/screen-temperature.json'
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text('{"active":true,"temperature":3500}')
    marker = directory / 'injected'
    poison = directory / 'poison'
    poison.mkdir(exist_ok=True)
    injection = f'#!/bin/sh\necho injected >> {shlex.quote(str(marker))}\nexit 99\n'
    for name in ('timeout', 'python3', 'bash', 'hyprctl', 'grep', 'head',
                 'pkill', 'setsid', 'uwsm-app', 'sleep', 'hyprsunset'):
        path = poison / name
        path.write_text(injection)
        path.chmod(0o755)
    startup = directory / 'startup'
    startup.write_text(injection)
    (home / '.bash_profile').write_text(injection)
    (poison / 'sitecustomize.py').write_text(f'open({str(marker)!r}, "a").write("python startup")')
    log = directory / 'commands.jsonl'
    temperature = directory / 'temperature'
    temperature.write_text('6500')
    ready = directory / 'ready'
    # Force recovery through pkill, setsid, uwsm-app, and the daemon launch.
    mock = directory / 'desktop-command'
    mock.write_text('''#!/usr/bin/python3
import json, os, pathlib, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
keys = ('PATH', 'HOME', 'XDG_CONFIG_HOME', 'XDG_RUNTIME_DIR', 'WAYLAND_DISPLAY',
        'HYPRLAND_INSTANCE_SIGNATURE', 'DBUS_SESSION_BUS_ADDRESS')
with open(LOG, 'a') as stream:
    stream.write(json.dumps({'name': name, 'argv': sys.argv[1:],
                            'env': {key: os.environ[key] for key in keys if key in os.environ},
                            'envKeys': list(os.environ)}) + '\\n')
if name == 'hyprctl':
    if not pathlib.Path(READY).exists(): sys.exit(1)
    if len(sys.argv) > 3: pathlib.Path(TEMPERATURE).write_text(sys.argv[3])
    print(pathlib.Path(TEMPERATURE).read_text())
elif name == 'uwsm-app':
    # Model a service manager restoring an unsafe environment.
    environment = dict(os.environ, BASH_ENV=STARTUP, PYTHONPATH=POISON)
    sys.exit(subprocess.run(sys.argv[2:], env=environment).returncode)
elif name == 'hyprsunset':
    pathlib.Path(READY).touch()
'''.replace('LOG', repr(str(log))).replace('READY', repr(str(ready)))
        .replace('TEMPERATURE', repr(str(temperature)))
        .replace('STARTUP', repr(str(startup))).replace('POISON', repr(str(poison))))
    mock.chmod(0o755)
    command = ['/usr/bin/bwrap', '--ro-bind', '/', '/', '--dev', '/dev', '--bind', str(directory), str(directory)]
    for name in ('hyprctl', 'pkill', 'uwsm-app', 'hyprsunset'):
        command += ['--ro-bind', str(mock), '/usr/bin/' + name]
    if missing:
        # A missing required utility must stop recovery before killing anything.
        command += ['--ro-bind', '/dev/null', '/usr/bin/sleep']
    command += ['--', '/usr/bin/qs', '-p', str(directory / 'shell.qml'), '--no-color']
    session = {
        'HOME': str(home),
        'XDG_CONFIG_HOME': str(home / '.config'),
        'XDG_RUNTIME_DIR': str(runtime),
        'WAYLAND_DISPLAY': 'test-wayland',
        'HYPRLAND_INSTANCE_SIGNATURE': 'test-instance',
        'DBUS_SESSION_BUS_ADDRESS': 'unix:path=' + str(runtime / 'test bus'),
    }
    environment = dict(os.environ, **session, PATH=str(poison) + ':/usr/bin',
                       BASH_ENV=str(startup), ENV=str(startup),
                       PYTHONPATH=str(poison), PYTHONHOME='/nonexistent-python-home',
                       LD_LIBRARY_PATH=str(poison),
                       QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='')
    try:
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=12)
    except subprocess.TimeoutExpired as error:
        assert not marker.exists(), 'inherited PATH or interpreter startup executed attacker code'
        raise AssertionError(str(error.stdout)[:4000] + '\ncommands: ' + (log.read_text() if log.exists() else 'none')) from error
    output = result.stdout + result.stderr
    assert not marker.exists(), 'inherited PATH or interpreter startup executed attacker code'
    assert result.returncode == 0 and 'PROCESS_TEST_PASS' in output, output
    saved = json.loads(state.read_text())
    assert saved == {'active': True, 'temperature': 4000}, saved
    records = [json.loads(line) for line in log.read_text().splitlines()]
    for record in records:
        assert record['env']['PATH'] == '/usr/bin:/bin', record
        allowed = set(session) | {'PATH', 'PWD', 'SHLVL', '_', 'LC_CTYPE'}
        assert set(record['envKeys']) <= allowed, record
        for key, value in session.items():
            assert record['env'][key] == value, record
    names = {record['name'] for record in records}
    if missing:
        assert names == {'hyprctl'}, names
    else:
        assert names == {'hyprctl', 'pkill', 'uwsm-app', 'hyprsunset'}, names
        assert temperature.read_text() == '4000'


with tempfile.TemporaryDirectory(prefix='screen-temperature process-') as temporary:
    for missing in (False, True):
        directory = Path(temporary) / str(missing)
        directory.mkdir()
        exercise(directory, missing)

print('test_process_security.py: PASS')
