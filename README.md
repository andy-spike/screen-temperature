# Screen Temperature

Control Hyprsunset temperature and schedule from the Omarchy bar.

## Features

- Toggle warm light on and off from the bar button.
- Adjust temperature with the mouse wheel or the panel slider.
- Run a daily schedule: warm in the evening, neutral in the night.
- Keep manual changes until the next schedule boundary.
- Answer the Nightlight IPC target, so `omarchy toggle nightlight` and `omarchy-toggle-nightlight` keep working.

## Requirements

- Omarchy with the Quickshell shell.
- `hyprsunset` (ships with Hyprland on Omarchy).
- `python3`, `bash`, and coreutils (`timeout`, `grep`, `pkill`, `sleep`).

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
| Schedule switch | Enable or disable the schedule |
| FROM / TO fields | Edit the warm window (24-hour time, e.g. `19:00`) |

The default schedule is warm from `19:00` to `04:00`. A manual change
overrides the schedule until the next boundary, then the schedule resumes.
Neutral temperature is 6500 K, which means the filter is off.

## State

State lives in `~/.config/omarchy/screen-temperature.json`. The plugin writes
only this file and never touches other user configuration.

## License

MIT — see [LICENSE](LICENSE).