# Driver Database and Configuration Specification

ParchProbe stores driver configuration definitions in a structured directory tree under `/usr/lib/parchprobe/db/`. Each driver definition is contained within its own directory and declared via a `PROBECONFIG` file written in TOML format.

## 1. Directory Hierarchy

The driver database is partitioned primarily by bus architecture, followed by driver category, and finally by configuration name:

```text
/usr/lib/parchprobe/db/
├── pci/
│   ├── graphic_drivers/
│   │   ├── video-linux/
│   │   │   ├── PROBECONFIG
│   │   │   └── hooks/
│   │   │       ├── post-install
│   │   │       └── post-remove
│   │   ├── video-modesetting/
│   │   │   └── PROBECONFIG
│   │   ├── video-nvidia/
│   │   │   ├── PROBECONFIG
│   │   │   └── hooks/
│   │   │       ├── post-install
│   │   │       └── post-remove
│   │   └── video-vesa/
│   │       └── PROBECONFIG
│   └── network_drivers/
│       ├── network-broadcom-wl/
│       │   ├── PROBECONFIG
│       │   └── hooks/
│       │       ├── post-install
│       │       └── post-remove
│       └── network-r8168/
│           ├── PROBECONFIG
│           └── hooks/
│               ├── post-install
│               └── post-remove
└── usb/
```

## 2. Top-Level Configuration Keys

A `PROBECONFIG` file defines the identity, requirements, and package dependencies of a driver.

| Key | Type | Default | Description |
|---|---|---|---|
| `name` | String | (Required) | Unique lowercase identifier for the driver profile. |
| `info` | String | `""` | Human-readable explanation of the driver functionality. |
| `version` | String | `""` | Release or profile version string. |
| `freedriver` | Boolean | `true` | Indicates whether the driver is open-source (`true`) or proprietary (`false`). |
| `priority` | Integer | `0` | Preference weight used during auto-installation. Higher values take precedence. |
| `depends` | Array of Strings | `[]` | Package names that must be installed by the package manager. |
| `conflicts` | Array of Strings | `[]` | Package names that must be removed prior to installing this driver. |
| `config_conflicts` | Array of Strings | `[]` | Driver profile name globs that cannot coexist with this driver. |
| `kernel_depends` | Array of Strings | `[]` | Package prefixes expanded dynamically for each detected kernel. |
| `kernel_conflicts` | Array of Strings | `[]` | Dynamic kernel package prefixes removed during installation. |
| `hooks_dir` | String | `""` | Relative path to the folder containing lifecycle hook scripts. |

## 3. Hardware Matching Table (`[[hardware]]`)

Each profile can declare one or more `[[hardware]]` tables. These tables specify the criteria for matching host devices.

| Key | Type | Description |
|---|---|---|
| `class_ids` | Array of Strings | Class code globs matching device functions (e.g. `["0300", "0302"]`). |
| `vendor_ids` | Array of Strings | Vendor hexadecimal globs (e.g. `["10de"]` for NVIDIA). |
| `device_ids` | Array of Strings | Inline device hexadecimal globs (e.g. `["*"]` or `["8168"]`). |
| `device_ids_file` | String | Relative path to an external file containing newline-separated device IDs. |
| `blacklist_class_ids` | Array of Strings | Class codes explicitly disqualified from matching. |
| `blacklist_vendor_ids` | Array of Strings | Vendor codes explicitly disqualified from matching. |
| `blacklist_device_ids` | Array of Strings | Device codes explicitly disqualified from matching. |

### 3.1 Matching Evaluation Rules

When evaluating whether a `PROBECONFIG` matches a given device on the system:

1. Disqualification Precedence: If the device attributes match any blacklist pattern defined in `blacklist_class_ids`, `blacklist_vendor_ids`, or `blacklist_device_ids`, the evaluation aborts and returns false.
2. Group Conjunction: Within an individual `[[hardware]]` group, the device must satisfy the class, vendor, and device ID requirements simultaneously.
3. Multi-Group Completeness: If a configuration specifies multiple `[[hardware]]` groups, every group must match at least one device on the host system. This ensures that multi-device configurations (such as hybrid GPU setups requiring both an integrated controller and a discrete controller) are only offered when all required hardware components are present.

### 3.2 External Identifier Files

When a driver supports thousands of distinct hardware revisions (such as legacy GPU chips), specifying all IDs inline can clutter the configuration file. The `device_ids_file` key allows referencing an external text file. The file format expects one hexadecimal ID per line. Empty lines and comment lines prefixed with `#` are ignored by the parser.

## 4. Configuration Examples

### 4.1 Standard Open Source Graphics (`video-linux`)

```toml
name = "video-linux"
info = "Standard open-source graphics drivers for AMD, Intel, NVIDIA (nouveau), and generic display controllers."
version = "2026.01.01"
freedriver = true
priority = 1

[[hardware]]
class_ids = ["0300", "0302", "0380"]
vendor_ids = ["1002", "8086", "10de", "1af4", "1013", "1234", "15ad", "1b36"]
device_ids = ["*"]

conflicts = ["nvidia", "nvidia-utils", "nvidia-dkms"]
depends = ["mesa", "xf86-video-amdgpu", "xf86-video-ati", "xf86-video-intel", "xf86-video-nouveau"]
config_conflicts = ["video-nvidia*"]

hooks_dir = "hooks"
```

### 4.2 Proprietary NVIDIA Graphics (`video-nvidia`)

```toml
name = "video-nvidia"
info = "Official proprietary NVIDIA graphics driver for modern GeForce, RTX, Quadro, and Tesla GPUs."
version = "2026.01.01"
freedriver = false
priority = 7

[[hardware]]
class_ids = ["0300", "0302"]
vendor_ids = ["10de"]
device_ids = ["*"]
blacklist_device_ids = [
    "0020", "0028", "0029", "002a", "002b", "002c", "002d",
    "0040", "0041", "0042", "0043", "0044", "0045", "0047", "0048",
    "0090", "0091", "0092", "0093", "0094", "0095", "0098", "0099"
]

conflicts = ["nvidia-390xx-utils", "nvidia-470xx-utils", "xf86-video-nouveau"]
depends = ["nvidia-utils", "nvidia-settings"]
config_conflicts = ["video-linux*", "video*nvidia*"]
kernel_depends = ["nvidia"]
kernel_conflicts = ["nvidia-390xx", "nvidia-470xx"]

hooks_dir = "hooks"
```
