# Screen Temperature

Control the Hyprsunset screen temperature from the Omarchy bar.

## Features

- Toggle warm light on and off from the bar button.
- Adjust temperature with the mouse wheel or the panel slider.
- Follow a `hyprsunset` schedule, so the panel shows what is actually on screen.
- Answer the Nightlight IPC target, so `omarchy toggle nightlight` and `omarchy-toggle-nightlight` keep working.

## Requirements

- Omarchy with the Quickshell shell.
- `hyprsunset` (ships with Hyprland on Omarchy).
- Bash, Python 3, coreutils, grep, procps-ng, util-linux, and UWSM.

The plugin uses the executables installed under `/usr/bin` on Omarchy.

The plugin owns the Hyprsunset daemon and the Nightlight IPC target. The
built-in Nightlight plugin must be disabled, or two plugins fight over the
daemon. See [Install](#install).

## Install

```sh
omarchy plugin add https://github.com/andy-spike/screen-temperature.git --enable
```

This adds the widget to the right side of the bar.

Disable the built-in Nightlight plugin:

1. Open `~/.config/omarchy/shell.json`.
2. Find the `disabledPlugins` list near the end of the file.
3. Add `"omarchy.nightlight"` when it is not present:

   ```json
   "disabledPlugins": [
     "omarchy.nightlight"
   ]
   ```

4. Save the file. The shell reads the change without a restart.

## Remove

```sh
omarchy plugin remove io.github.andy-spike.screen-temperature
```

Removal leaves no daemon or service behind. The state file below remains; it
is safe to delete.

## Usage

| Action | Result |
| --- | --- |
| Left click | Open / close the panel |
| Right click | Toggle warm light |
| Mouse wheel | Adjust temperature by one step |
| Panel slider | Pick a temperature |
| Panel switch | Toggle warm light |

Temperature moves in fixed steps from 2000 K to 6500 K. Neutral is 6500 K,
which means the filter is off; picking it turns the widget off and keeps the
previous warm value for the next toggle.

## Schedule

Scheduling belongs to `hyprsunset`, not to this plugin. Put profiles in
`~/.config/hypr/hyprsunset.conf`:

```
profile {
    time = 19:00
    temperature = 3000
}
profile {
    time = 04:00
    temperature = 6500
}
```

The panel follows the daemon: when a profile fires, the readout, the slider,
and the bar icon move to match it. A change you make by hand holds until the
next profile time, because `hyprsunset` applies a profile only at its boundary.

Write the neutral profile as `temperature = 6500`, not `identity = true`.
`hyprctl hyprsunset temperature` reports the last temperature that was *set*,
so an identity profile reads back as the previous warm value and the panel
would show a filter that is not on screen.

Restart the daemon after editing the file; it reads the config at startup.

## State

State lives in `~/.config/omarchy/screen-temperature.json`, written directly
by the panel. The plugin writes only this file and never touches other user
configuration.
At startup, the panel applies the saved state. With no saved active state, it
starts disabled at 6500 K, even if Hyprsunset starts at 6000 K.

The path is predictable, so the panel treats the file as untrusted input. A
helper opens it without following links, verifies that it is a regular file,
and reads at most 4 KB through the same descriptor. Invalid state is left alone
and the panel starts from defaults.

## Child processes

The panel clears the inherited environment before starting each child process.
It passes only a fixed system `PATH` and the session values needed for state
files, Hyprland, Wayland, and D-Bus. Commands use absolute executable paths.
Python runs in isolated mode without site initialization. Bash does not load
profile files, and its environment does not include startup hooks.

Daemon recovery checks all required tools before stopping Hyprsunset. The
command sent through UWSM also rebuilds the daemon environment, because UWSM
has a separate launch environment. A missing tool causes recovery to fail.

## Development

```sh
node test_temperature_steps.js   # step snapping and naming
python3 test_state_file.py       # safe, bounded state-file access
python3 test_process_security.py # Quickshell process tests; requires bubblewrap
./reload.sh                      # install into the running shell and restart it
```

## License

MIT — see [LICENSE](LICENSE).
