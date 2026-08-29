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
- `bash` and coreutils (`timeout`, `grep`, `pkill`, `sleep`).

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

The path is predictable, so the panel treats the file as untrusted input: it is
read only when it is under 4 KB, which no state of ours ever reaches. A larger
file at that path is emptied and the panel starts from defaults.

## Development

```sh
node test_temperature_steps.js   # step snapping and naming
./test_state_guard.sh            # size cap on the state file
./reload.sh                      # install into the running shell and restart it
```

## License

MIT — see [LICENSE](LICENSE).
