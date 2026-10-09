# ParchProbe Command Line Reference

ParchProbe provides an interface for inspecting host hardware, querying driver compatibility, and performing system driver installations and removals.

## 1. Command Syntax

```text
parchprobe [OPTIONS] <COMMAND> [ARGS...]
```

When invoked without a command, ParchProbe defaults to executing `list`.

## 2. Command Overview

| Command | Privilege Level | Description |
|---|---|---|
| `list` | User | Displays hardware devices and drivers available for installed components. |
| `list-all` | User | Displays every driver configuration found in the database. |
| `list-installed` | User | Displays all driver configurations currently registered in the state database. |
| `list-hardware` | User | Lists all detected PCI and USB devices along with identifier strings. |
| `install <bus> <cfg...>` | Root | Installs one or more driver configurations for the specified bus. |
| `remove <bus> <cfg...>` | Root | Removes one or more installed driver configurations. |
| `install-custom <bus> <path>` | Root | Installs a driver from a specified local directory containing a PROBECONFIG file. |
| `auto <bus> <free\|nonfree> <class>` | Root | Automatically selects and installs the highest priority driver for a device class. |

## 3. Global Options

| Option | Argument | Description |
|---|---|---|
| `--pci` | None | Restricts hardware queries and driver operations to the PCI bus. |
| `--usb` | None | Restricts hardware queries and driver operations to the USB bus. |
| `--detail` | None | Displays verbose hardware specifications and detailed configuration summaries. |
| `--force` | None | Reinstalls a driver configuration even if already marked as installed. |
| `--json` | None | Emits machine-readable JSON output to standard output. |
| `--pmroot` | Path | Sets an alternate root directory for package manager operations. |
| `--pmconfig` | Path | Sets an alternate configuration file for the package manager. |
| `--pmcachedir` | Path | Sets an alternate cache directory for package downloads. |
| `-h`, `--help` | None | Prints the program help summary and exits. |
| `-v`, `--version` | None | Prints the program version and license information. |

## 4. Query Commands

### 4.1 `list`

The `list` command scans system buses, queries the driver database, and prints a tabular summary matching each device to compatible drivers.

Default output format:
```text
CLASS    VENDOR   DEVICE   BUS    CONFIGS
-------- -------- -------- ------ -------
0300     10de     28e0     pci    video-nvidia, video-linux, video-modesetting, video-vesa
0200     10ec     8168     pci    network-r8168
```

When invoked with `--detail`, each detected device is printed with full descriptions resolved from `pci.ids` or `usb.ids`, including human-readable vendor names, device names, and available configuration profiles.

### 4.2 `list-all`

The `list-all` command iterates through all driver configurations stored under `/usr/lib/parchprobe/db/` and lists their names, version strings, licensing categories, and bus types.

Output format:
```text
NAME                 VERSION         FREE   BUS
-------------------- --------------- ------ -----
video-linux          2026.01.01      true   pci
video-modesetting    2026.01.01      true   pci
video-nvidia         2026.01.01      false  pci
network-r8168        2026.01.01      true   pci
```

### 4.3 `list-installed`

The `list-installed` command reads `/var/lib/parchprobe/state.toml` and presents all currently installed configurations.

Output format:
```text
NAME                 BUS    SOURCE
-------------------- ------ --------------------
video-nvidia         pci    /usr/lib/parchprobe/db/pci/graphic_drivers/video-nvidia
```

### 4.4 `list-hardware`

The `list-hardware` command prints every detected PCI and USB device without evaluating driver compatibility. It is useful for hardware auditing and diagnostics.

## 5. Transaction Commands

### 5.1 `install`

Installs the requested driver configuration. If the driver requires package dependencies, ParchProbe calls the package manager to download and configure them. If another installed driver is marked as conflicting in `config_conflicts`, installation aborts with an error code.

Example:
```bash
sudo parchprobe install pci video-nvidia
```

### 5.2 `remove`

Uninstalls the specified driver. Any pre-remove and post-remove scripts are executed, associated package dependencies are removed if safe, and the driver entry is purged from the state file.

Example:
```bash
sudo parchprobe remove pci video-nvidia
```

### 5.3 `auto`

The `auto` command automates hardware driver setup for installation scripts and system initializers. It accepts three positional parameters: bus type, driver license classification (`free` or `nonfree`), and four-digit device class hexadecimal string.

Example for graphics devices:
```bash
sudo parchprobe auto pci free 0300
```

When executed, the engine locates all host devices matching class `0300`, filters drivers matching the requested license policy, selects the configuration with the highest numerical priority, and executes the installation transaction.

## 6. JSON Output Schema

When the `--json` option is specified, standard output emits valid JSON suitable for consumption by graphical user interfaces and automation tools.

### 6.1 Hardware and Available Configurations Schema

```json
{
  "devices": [
    {
      "bus": "pci",
      "id": "0000:01:00.0",
      "class_id": "0300",
      "vendor_id": "10de",
      "device_id": "28e0",
      "class_name": "Display controller",
      "available": ["video-nvidia", "video-linux", "video-modesetting", "video-vesa"],
      "installed": ["video-nvidia"]
    }
  ]
}
```

### 6.2 Transaction Response Schema

Successful transaction:
```json
{
  "status": "ok"
}
```

Failed transaction:
```json
{
  "status": "error",
  "message": "ConfigConflict"
}
```

## 7. Exit Codes

| Code | Label | Meaning |
|---|---|---|
| 0 | Success | The operation completed successfully. |
| 1 | Failure | An error occurred during hardware detection, matching, or transactions. |
