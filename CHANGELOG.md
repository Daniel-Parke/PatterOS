# Changelog

All notable changes to PatterOS are recorded here. Dates are DD Month YYYY.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
loosely: the point is that someone who ran an older version can tell what
changed on their machine and why it matters to them.

## [1.4] - 15 August 2026

The correctness release. Everything here is a fix to something that was already
shipping, and two of them could cost you an evening.

### Fixed

- **`--models-max` was set to `0` on CPU-only machines, which means *unlimited*,
  not "none".** llama.cpp's own `common/arg.cpp` documents `0 = unlimited`, and
  three places in `tools/server/server-models.cpp` treat any value `<= 0` as no
  limit, switching off the capacity check, the eviction of idle models and the
  request queue. Because the context size applies per model and each model runs
  as its own process, memory could grow without bound, on exactly the machines
  least able to cope. It is now `1` everywhere. The manual guide had the same
  error and has been corrected too.
- **The GPU was not being used on installs from before 18 June 2026.** The
  installer tracked the latest llama.cpp. Until upstream tag `b9702` the router
  accepted `--gpu-layers`, `--ctx-size` and `--jinja` and then silently
  discarded them, so every model ran on upstream defaults. The build is now
  pinned to a tested tag (`b10313`).
- **Re-running the installer destroyed service files you had edited.** The
  manual guide tells you to edit them, to add an API key or to let another
  machine connect, while the installer promised re-running was safe. Both could
  not be true. Service files are now checksummed: PatterOS updates the ones it
  wrote and leaves yours alone, keeping a copy either way. Use
  `--replace-units` if you want the standard version back.
- **Odysseus was cloned from an address that could be taken over.** The old
  location redirects to the project's real home, but through a name its previous
  owner no longer uses. Had that name been reused, the installer would have
  downloaded and run whatever was put there. It now clones the canonical
  address and pins a specific commit, so everyone installs the same code.
- **The Odysseus first-run password was never captured.** The installer searched
  the setup output for it, but upstream only prints that line when it is not
  attached to a terminal, which under the installer it always is. PatterOS now
  sets the password itself and writes it to a root-only file instead of printing
  it to the screen.
- **Turning on the firewall could lock you out over SSH.** The old code allowed
  the standard port 22 and then enabled the firewall. Anyone running SSH on a
  different port lost access to their own machine. The real port is now read
  from the SSH server before anything is enabled.
- **Driver health was misread on non-English systems.** PatterOS classifies the
  NVIDIA driver by matching words in `nvidia-smi` output. On a French or German
  system it fell through to "broken" and reinstalled a driver that only needed a
  reboot, which is the exact problem that check exists to prevent.
- **`--full` could run your card out of memory.** It claimed to need a 24 GB
  card and checked neither the card nor the disk, then downloaded tens of
  gigabytes. Disk and memory are now checked first, and the number of layers
  placed on the GPU is worked out from your actual card instead of always
  assuming the whole model fits. Override with `NGL=<number>`.
- **Downloads reported success even when nothing arrived.** Each file is now
  checked for existence and a plausible size, and `huggingface-cli` is used
  when the newer `hf` command is not present.
- **The uninstaller exited with an error after a successful run.** Its last
  statement was a condition that is false on a real run, so a completed reset
  reported failure and only a dry run reported success. Anything scripted around
  it was told the wrong thing.
- **The uninstaller assumed default ports.** If you changed them during install,
  it removed firewall rules that were never added and left yours in place. It
  now reads the ports back out of the installed service files.
- **The uninstaller left you in groups PatterOS added.** It now removes them, and
  only the ones PatterOS recorded adding, so a group you were already in is
  untouched.

### Added

- A short hardware check before anything is changed. PatterOS shows what it
  thinks your processor, graphics card, memory and free disk are, and asks you
  to confirm it looks right. It also says plainly that the driver step is the
  one part carrying real risk, and that nothing has been changed yet. Skipped
  with `-y`.
- Resizable BAR, Mesa version and Vulkan driver checks on AMD and Intel. A
  disabled Resizable BAR roughly halves speed and looks like nothing is wrong;
  PatterOS now detects it, works around it and tells you the real fix.
- `--replace-units` to overwrite service files deliberately.
- `NGL`, `CTX` and `LLAMA_VERSION` documented as environment settings.
- The Part 2 manual setup guide and the Local AI Handbook, published in `docs/`.
  The installer's "see the guide, Step 10" messages now point at something you
  can actually open.
- A test suite: 25 assertions across service-file preservation, uninstall
  reversal, and agreement between the scripts and the documentation. Continuous
  integration runs shellcheck, the tests, and a check that the Part 1 guide has
  not gone stale.

### Changed

- Models are now the QAT builds of Gemma 4, which are 0.6 to 1.6 GB smaller
  each at the same quantisation. There is no verified quality comparison between
  the two, so no claim is made about that; the saving in disk space is the
  reason.
- LACT updated to v0.10.0.
- The installer is `install_local_ai.sh` everywhere. The header, banner and help
  called it `setup_local_ai.sh`, which is not the name of the file and not what
  the video links to.
- Installer and uninstaller versions are matched again, at v1.4.
- The error message on failure no longer claims "nothing was changed", which was
  not true by the time most errors happen.
- The Part 1 BOM guide corrected in place: ports, workspace application, the
  AMD graphics path, the multi-GPU claim, and the repository link.

### Removed

- The reference to a "full PatterOS `install.sh`" holding the heavy
  provisioning. No such file has ever existed.

## [1.3] - June 2026

Companion release to Part 2 of the video series. Initial public installer and
uninstaller.

[1.4]: https://github.com/Daniel-Parke/PatterOS/releases/tag/v1.4
