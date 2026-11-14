# tmux .deb Package Builder

[![CI](https://github.com/brozi/tmux-builder/actions/workflows/ci.yml/badge.svg)](https://github.com/brozi/tmux-builder/actions/workflows/ci.yml)
[![Daily Release Check](https://github.com/brozi/tmux-builder/actions/workflows/daily-release-check.yml/badge.svg)](https://github.com/brozi/tmux-builder/actions/workflows/daily-release-check.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

An automated build system and repository for packaging universal Debian/Ubuntu (`.deb`) packages of **tmux** from the official [`tmux/tmux-builds`](https://github.com/tmux/tmux-builds) releases.

---

## Highlights

- **Daily Automated Release Monitoring:** A scheduled GitHub Actions workflow checks daily for new upstream releases from `tmux/tmux-builds`. When a new release is detected, it automatically packages `.deb` files for both architectures, verifies them, and publishes a new GitHub Release with checksums.
- **Universal Multi-Distribution Compatibility:** Statically compiled with `musl-libc` and packaged with standard `xz` compression (`dpkg-deb -Zxz`) to ensure flawless compatibility across older and modern Debian/Ubuntu releases without needing separate duplicate builds.
- **Architectures Supported:**
  - `amd64` (`x86_64`)
  - `arm64` (`aarch64`)
- **Proper Debian Packaging:** Includes `/usr/bin/tmux` (mode 0755), compressed man page `/usr/share/man/man1/tmux.1.gz`, standard `copyright` consolidating upstream licenses (tmux, musl, libevent, ncurses, utf8proc), and `DEBIAN/md5sums`.
- **Easy Customization:** Package details and metadata (description, maintainer, section, priority, etc.) can be modified in [`package.env`](package.env) or [`debian/control.template`](debian/control.template).

---

## Distribution Compatibility

Because the upstream binary is statically linked and the packages use standard `xz` compression, the generated packages run universally on:

| Distribution | Releases / Codename | Architecture | Status |
| :--- | :--- | :--- | :--- |
| **Debian** | 11 (`bullseye`), 12 (`bookworm`), 13 (`trixie`), 14 (`forky`), `sid` | `amd64`, `arm64` | Verified |
| **Ubuntu** | 22.04 LTS (`jammy`), 24.04 LTS (`noble`), 25.10 (`questing`), 26.04 LTS (`resolute`) | `amd64`, `arm64` | Verified |

> **Note on Debian 11 (Bullseye):** Debian 11's `dpkg` does not support `zstd` payload compression. By explicitly building packages with `xz` compression (`-Zxz`), these packages install seamlessly on Debian 11 as well as all modern Debian and Ubuntu releases.

---

## Quick Start: Installing Pre-built Packages

Download the `.deb` file for your architecture from the [Releases](https://github.com/brozi/tmux-builder/releases) tab and install:

```bash
# For x86_64 / amd64:
sudo dpkg -i tmux_<version>-1_amd64.deb

# For ARM64 / aarch64:
sudo dpkg -i tmux_<version>-1_arm64.deb

# Verify installation:
tmux -V
```

---

## Customizing Package Details

Package metadata can be edited in [`package.env`](package.env):

```bash
PACKAGE_NAME="tmux"
PACKAGE_REVISION="1"
MAINTAINER="Brozi <jasiubar@gmail.com>"
SECTION="admin"
PRIORITY="optional"
HOMEPAGE="https://tmux.github.io/"
DESCRIPTION_SUMMARY="terminal multiplexer"
```

You can also customize the raw Debian control template directly in [`debian/control.template`](debian/control.template) to add fields like `Suggests:` or `Enhances:`.

You can also override parameters on the fly via command-line arguments:
```bash
./scripts/build-deb.sh --maintainer "Your Name <you@example.com>" --revision 2
```

---

## Building Locally

### Prerequisites
- `dpkg-deb`, `curl`, `tar`, `gzip`, `xz-utils`, `python3` (all pre-installed on Debian/Ubuntu).

### Usage

```bash
# Build the latest upstream release for your current host architecture:
make build

# Build universal packages for both amd64 and arm64:
make build-all

# Build a specific version:
make build-all VERSION=3.8

# Build the latest upstream preview (git master) build:
make preview

# Check upstream for new releases:
make check

# Test and verify built packages:
make test

# Clean build directory:
make clean
```

All built `.deb` packages and `.sha256` checksums are placed into the `dist/` directory:
```
dist/
├── tmux_3.8-1_amd64.deb
├── tmux_3.8-1_amd64.deb.sha256
├── tmux_3.8-1_arm64.deb
└── tmux_3.8-1_arm64.deb.sha256
```

---

## Building with Docker

If you are on macOS, Windows, or a non-Debian Linux system, you can build without installing any packaging tools on your host:

```bash
# Build both amd64 and arm64 packages inside a container:
make docker-build

# Or with docker compose:
docker compose up --build
```

---

## Automated GitHub Actions

The repository includes three automated workflows:

1. **`daily-release-check.yml`:**
   - Runs automatically on a daily cron schedule (`0 4 * * *`) and via `workflow_dispatch`.
   - Checks `tmux/tmux-builds` for new releases.
   - If a new release is detected, builds `amd64` and `arm64` packages, runs the test suite, and creates a new GitHub Release with the packages and `SHA256SUMS` attached.
2. **`build-deb.yml`:**
   - Manual workflow dispatch to build on demand for any version (`latest`, `3.8`, `preview`), target architecture, or revision.
3. **`ci.yml`:**
   - Continuous integration testing on pushes and pull requests to ensure build and test scripts pass cleanly.

---

## Repository Layout

```
tmux-builder/
├── .github/
│   └── workflows/
│       ├── daily-release-check.yml  # Daily cron check & automated release publisher
│       ├── build-deb.yml            # Manual on-demand package builder
│       └── ci.yml                   # CI test runner
├── debian/
│   ├── control.template             # Debian DEBIAN/control template
│   └── README.Debian                # Package documentation & static build notice
├── scripts/
│   ├── check-upstream.sh            # Release checker for tmux-builds
│   ├── build-deb.sh                 # Main CLI package builder
│   └── test-deb.sh                  # Comprehensive .deb validation suite
├── package.env                      # Package details & metadata configuration
├── Dockerfile                       # Containerized build environment
├── docker-compose.yml               # Compose file for Docker builds
├── Makefile                         # Convenient make targets
├── LICENSE                          # MIT License
└── README.md                        # Project documentation
```

---

## License

This packaging project is released under the [MIT License](LICENSE).  
The packaged `tmux` binary and libraries are licensed under their respective open-source licenses (ISC, BSD, MIT) detailed in the package's `copyright` file.
