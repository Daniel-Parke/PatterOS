# PatterOS

Companion files for the **PatterOS · Local AI Budget Build** YouTube series, hardware guides, installers, and documentation from [PatterTech](https://github.com/Daniel-Parke).

This repository is organised around two videos. Each section below tells you where to find the files in this repo.

---

## Part 1, Hardware BOM & build guide

**What it covers:** choosing parts, building the rig, and the bill of materials for the budget local-AI workstation.

**Find the guide in this repo:**

| File | Location |
|------|----------|
| BOM & build guide (Word) | [`docs/PatterOS_AI_Rig_BOM_and_Build_Guide.docx`](docs/PatterOS_AI_Rig_BOM_and_Build_Guide.docx) |

On GitHub: open the [`docs/`](docs/) folder and download `PatterOS_AI_Rig_BOM_and_Build_Guide.docx`.

---

## Part 2, Software setup (install & uninstall)

**What it covers:** turning a fresh Linux Mint or Ubuntu machine into a local AI workstation, drivers, llama.cpp, models, Odysseus workspace, and firewall.

**Find the scripts and the guide in this repo:**

| File | Location | Purpose |
|--------|----------|---------|
| Installer | [`scripts/install_local_ai.sh`](scripts/install_local_ai.sh) | Automates the Part 2 manual setup guide |
| Uninstaller | [`scripts/uninstall_local_ai.sh`](scripts/uninstall_local_ai.sh) | Removes Part 2 services and resets the machine |
| Manual setup guide | [`docs/part-2-manual-setup-guide.md`](docs/part-2-manual-setup-guide.md) | The same setup by hand, one step at a time, with every command explained |

Prefer not to run someone else's script on a new machine? That is a sensible
instinct. The [manual setup guide](docs/part-2-manual-setup-guide.md) does the
same job by hand, and the installer's Step 10, 11 and 12 references point at it.

**Quick start** (on the target machine, after cloning or downloading this repo):

```bash
# Read the script first, never blind-run from the internet
less scripts/install_local_ai.sh

# Run interactively
sudo bash scripts/install_local_ai.sh

# Or non-interactive (after you've read the script)
sudo bash scripts/install_local_ai.sh -y
```

See the header comments in [`scripts/install_local_ai.sh`](scripts/install_local_ai.sh) for flags (`--full`, `--no-models`, `--cpu`, etc.) and [`scripts/uninstall_local_ai.sh`](scripts/uninstall_local_ai.sh) for removal options, or run either with `--help`.

---

## Part 3, Comparing models

**What it covers:** the same hard research task run across nine model and
quantisation combinations on the same machine, unedited, so you can see for
yourself how small you can go before it stops being useful.

| File | Location |
|------|----------|
| Test results and method | [`docs/model-tests/`](docs/model-tests/) |

---

## Going further

**What it covers:** the ideas behind the commands. What a model actually is, how
the pieces fit together, how to choose one, and what local AI can realistically
do for you. No background assumed.

| File | Location |
|------|----------|
| The Local AI Handbook | [`docs/local-ai-handbook.md`](docs/local-ai-handbook.md) |

---

## Third-party software this installs

PatterOS sets these up for you, and each one is optional. They are separate
projects with their own licences, and PatterOS does not claim them:

| Project | Licence | What it does here |
|---------|---------|-------------------|
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | MIT | Runs the models. Built from source and pinned to a tested tag |
| [Odysseus](https://github.com/odysseus-dev/odysseus) | AGPL-3.0 | The web workspace. Installed and run, never modified or redistributed |
| [LACT](https://github.com/ilya-zlobintsev/LACT) | MIT | Optional GPU power and fan tuning |
| Gemma 4 model weights | Apache 2.0 | The models themselves, downloaded from Hugging Face |

---

## Licensing

Source code and technical documentation in this repository are licensed under the [Apache License 2.0](LICENSE). See also [NOTICE](NOTICE).

The names **Patter**, **PatterOS**, **PatterTech**, and related marks, plus the official visual identity in [`branding/`](branding/), are **not** part of that license. See [TRADEMARK.md](TRADEMARK.md). If you distribute a modified version, see [REBRANDING.md](REBRANDING.md).
