# PatterOS

Companion files for the **PatterOS · Local AI Budget Build** YouTube series — hardware guides, installers, and documentation from [PatterTech](https://github.com/Daniel-Parke).

This repository is organised around two videos. Each section below tells you where to find the files in this repo.

---

## Part 1 — Hardware BOM & build guide

**What it covers:** choosing parts, building the rig, and the bill of materials for the budget local-AI workstation.

**Find the guide in this repo:**

| File | Location |
|------|----------|
| BOM & build guide (Word) | [`docs/PatterOS_AI_Rig_BOM_and_Build_Guide.docx`](docs/PatterOS_AI_Rig_BOM_and_Build_Guide.docx) |

On GitHub: open the [`docs/`](docs/) folder and download `PatterOS_AI_Rig_BOM_and_Build_Guide.docx`.

**Vision & mission (optional reading):** [`docs/PatterOS Vision - Operation Level Playing Field.md`](docs/PatterOS%20Vision%20-%20Operation%20Level%20Playing%20Field.md)

---

## Part 2 — Software setup (install & uninstall)

**What it covers:** turning a fresh Linux Mint or Ubuntu machine into a local AI workstation — drivers, llama.cpp, models, Odysseus workspace, and firewall.

**Find the scripts in this repo:**

| Script | Location | Purpose |
|--------|----------|---------|
| Installer | [`scripts/install_local_ai.sh`](scripts/install_local_ai.sh) | Automates the Part 2 manual setup guide |
| Uninstaller | [`scripts/uninstall_local_ai.sh`](scripts/uninstall_local_ai.sh) | Removes Part 2 services and resets the machine |

**Quick start** (on the target machine, after cloning or downloading this repo):

```bash
# Read the script first — never blind-run from the internet
less scripts/install_local_ai.sh

# Run interactively
sudo bash scripts/install_local_ai.sh

# Or non-interactive (after you've read the script)
sudo bash scripts/install_local_ai.sh -y
```

See the header comments in [`scripts/install_local_ai.sh`](scripts/install_local_ai.sh) for flags (`--full`, `--no-models`, `--cpu`, etc.) and [`scripts/uninstall_local_ai.sh`](scripts/uninstall_local_ai.sh) for removal options.

---

## Licensing

Source code and technical documentation in this repository are licensed under the [Apache License 2.0](LICENSE). See also [NOTICE](NOTICE).

The names **Patter**, **PatterOS**, **PatterTech**, and related marks, plus the official visual identity in [`branding/`](branding/), are **not** part of that license. See [TRADEMARK.md](TRADEMARK.md). If you distribute a modified version, see [REBRANDING.md](REBRANDING.md).
