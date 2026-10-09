# parchprobe

Hardware detection and driver configuration tool for Parch GNU/Linux.

`parchprobe` scans the system's PCI and USB buses, matches detected devices
against a database of driver configurations, and installs or removes the
corresponding packages and configuration files through `ALPM`.

## Build

```sh
zig build
zig build test
```

## License

AGPL-3.0-only. See [LICENSE](./LICENSE).
