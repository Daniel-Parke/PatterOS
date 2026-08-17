# Changelog

All notable changes to PatterOS are recorded here. Dates are DD Month YYYY.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
loosely: the point is that someone who ran an older version can tell what
changed on their machine and why it matters to them.

## [Unreleased]

Found while building out the test suite for the installer and then running it
for real, twice, on an RTX 3090 Ti, and then again on an RX 7900 XTX. Every fix
below shares a shape: the script reported success while quietly doing something
other than what it said.

### Fixed

- **AMD VRAM was invisible unless `mesa-utils` happened to be installed.**
  `vram_gb()` asked `nvidia-smi`, then `glxinfo`. `glxinfo` comes from
  `mesa-utils`, which is not in the base package list, so a machine that only
  has what this installer put on it has neither. Resizable BAR detection and
  the partial `-ngl` offload both use that number, so an AMD or Intel card
  with ReBAR off and an 8 GB card asked to hold a 19 GB model both took the
  `-ngl 999` path and skipped the workaround. The function now reads
  `/sys/class/drm/card*/device/mem_info_vram_total` when the two userland
  tools are missing.
- **The graphics driver was reported as "Mesa Overlay".** `vulkaninfo --summary`
  lists instance layers first, and one of them is named `Mesa Overlay layer`.
  Matching `/driverInfo|Mesa/` took that line, so a current Mesa 25.2.8 install
  was printed as the overlay layer instead of the driver. The parser now reads
  `driverInfo` only.
- **`-y --replace-units` said it had kept the edited unit, then replaced it.**
  `install_unit()` printed "your version is kept" whenever `-y` was set, and
  only afterwards noticed `--replace-units`. The keep message is now skipped
  when replacement was requested.
- **`--cpu --skip-build` on an AMD Vulkan install stripped the ReBAR workaround
  from the live service.** `--cpu` skipped PCI detection entirely, so
  `vulkan_health` never ran, `VK_ENV` stayed empty, and the unit rewrite dropped
  `GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM` and `RADV_PERFTEST` while still running
  the vulkan binary (`-ngl 999`). The card is now still detected under `--cpu`,
  and if the engine being reused is vulkan the workarounds are filled in before
  the unit is written.

- **The workspace could not start at all, and the installer said it had.**
  Odysseus is pinned to a specific commit so that everyone installs the same
  code. That commit, the tip of upstream's `main`, annotates two helpers in
  `src/agent_loop.py` with `dict[str, Any]` without importing `Any`, so the
  module raises `NameError` before the web server ever binds its port. Upstream
  fixed it on their `dev` branch (`d96c7af`, "import Any for tool event helper")
  and never merged it to `main`. The effect on a new install was a workspace that
  started, died, and was restarted every ten seconds for ever, while the closing
  summary printed `http://localhost:7000` and invited you to log in. The
  installer now carries that one-line upstream fix, applied only when that exact
  defect is present, so it becomes a no-op as soon as upstream merges.
- **`systemctl is-active` was being used as a health check, moments after
  starting the service.** These units are `Type=simple`, so systemd calls them
  active the instant the process is forked, whether or not it survives. That is
  what let a crash-looping workspace be reported as installed and working. Both
  services are now watched until they either answer on their port or visibly
  fail, the restart counter is used to catch a service that is dying and being
  restarted, and the last few lines of the service log are printed inline so the
  real error is on screen rather than behind a `journalctl` command. The closing
  summary now says `NOT RUNNING` instead of printing a URL for something that
  is down, and makes clear the model server is still usable on its own.
- **`--lact` silently failed to remove LACT on any normal machine.** The check
  was `dpkg -l | grep -q '^ii  lact '`. Under `set -o pipefail`, `grep -q` exits
  at its first match and closes the pipe, so `dpkg` (a few hundred KB of output,
  far more than a pipe holds) dies of SIGPIPE and the pipeline reports failure
  even though the match succeeded. Measured on the test machine: exit 141, with
  `grep` itself returning 0 and LACT definitely installed. Every early-exit
  pipeline of that shape in both scripts has been replaced, because whether it
  bites depends on how much output there is and how far down the match sits,
  which is why it looked intermittent.
- **The uninstaller claimed to have removed firewall rules that were still
  there.** Same SIGPIPE cause in the check that reads the rules back, so the
  verification quietly inverted itself. Two related problems went with it: the
  rules for ports 8020 and 7000 were described as "ours" when the installer only
  ever opens SSH, so they can only have been added by hand following Step 10 or
  11 of the guide; and `ufw delete allow 8020/tcp` does not match a rule added
  as `ufw allow 8020`, yet still exits 0. Rules are now removed only if they
  exist, in either form, the removal is confirmed by reading the rules back, and
  the message credits them to the person who added them. If one cannot be
  removed, that is stated along with the exact command to finish the job and a
  note that a rule for a port nothing listens on opens nothing.
- **The uninstaller's closing summary listed deletions that never happened.** It
  printed "Removed: services + ~/llama.cpp + ~/odysseus" on every run, including
  on a machine where none of those existed. It now lists only what actually
  went, and says so plainly when that was nothing.
- **`LLAMA_VERSION` was ignored whenever `~/llama.cpp` already existed.** The
  step header announced the requested version, no git command ran, and whatever
  was already on disk got compiled. `--rebuild` did not help either: it
  recompiled the same old source. This mattered most to anyone who followed the
  manual guide first, since cloning llama.cpp yourself leaves you on `master`:
  the pin exists because before tag `b9702` the router accepted `-ngl` and `-c`
  and then discarded them, so you would get a service that looks perfectly
  healthy and runs entirely on the CPU. An existing checkout is now moved to the
  pinned version, or left alone with an explanation if you have uncommitted
  changes in it.
- **Changing a setting and re-running left the old setting running.** Editing
  the port or the context window rewrote the service file, and `systemctl
  enable --now` then did nothing at all, because starting an already-running
  service is a no-op. The summary reported the new value while the old process
  kept serving. Units that actually changed are now restarted; ones that did not
  are left undisturbed, so a re-run no longer drops a loaded model for nothing.
- **A busy port was reported as an NVIDIA driver problem, and then as success.**
  If anything else already held port 8020, the service could not bind, the only
  message said the driver probably needed a reboot, and the readiness check then
  talked to whichever program *did* own the port and announced a working server.
  The plan now warns about a port that is already in use, while it can still be
  changed for free, and the readiness check confirms our own service is running
  before it trusts an answer on the port.
- **The uninstaller's "never delete outside your home" guard did not hold for
  every home.** With a home directory of `/`, paths like `//llama.cpp` counted
  as being inside it, so the check that exists to catch the unexpected passed
  deletions at the top of the filesystem straight through. Both scripts now stop
  if the home directory is `/`.

### Added

- Three new test suites covering ground that had none: every prompt a user sees
  driven through a pseudo-terminal (both confirmation gates, the Customise and
  skip-phases dialogues, the edited-service-file question and the offer to
  reboot), every command-line flag and environment override, and every
  uninstaller flag including `--dry-run`, `--all` and the deletion guard rails.
  With the existing hardware matrix that is 459 assertions in the stubbed
  suites, plus the uninstaller reversal checks that still run only in a
  disposable container.

### Changed

- The closing summary no longer suggests a command that does not work yet. `hf`
  is installed into `~/.local/bin`, which Mint and Ubuntu add to `PATH` from
  `~/.profile` at login, so "Add a model: hf download ..." fails in the very
  terminal the installer just finished in. It now says to open a new terminal
  first. The three paragraphs of pip warnings about that same directory are
  suppressed, since the script already handles it and they arrive right after
  the longest wait in the install.
- `Odysseus log/pw` in the summary is now `Odysseus log`. The first-run password
  goes to a root-only file and is deliberately never printed, so offering the
  journal as a way to find it was a leftover from when it was.
- The workspace service gets a start limit, so a workspace that cannot start
  gives up after ten attempts instead of retrying every ten seconds for ever on
  a machine whose owner has been told everything is fine.
- The stub harness is now faithful in eight places where it was not, each of
  which had been hiding or inventing a failure: a masked command is genuinely
  absent from `PATH` rather than merely broken, a checkout remembers which tag
  it is at, `systemctl status` can report a unit it does not know, the restart
  counter can climb so a crash loop is reachable in a test, `ufw` keeps track of
  which rules it has deleted and refuses a `/tcp` delete for a rule stored
  without a protocol, `dpkg -l` can pad its output past a pipe buffer, and
  `STUB_HAS_HF=0` now masks a real `hf` on `PATH` the same way `nvcc` is masked.
  That last one matters: against a developer machine with `huggingface_hub`
  in `~/.local/bin`, the "only huggingface-cli" case called the real downloader.
  The `--lact` SIGPIPE bug passed against a three-line stub on every run. The
  hardware matrix also resets its scratch home, so running it twice in a row no
  longer produces different results. The vulkaninfo stub prepends the Mesa
  Overlay instance layer so the driver-version parser cannot quietly match it.

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
  when the newer `hf` command is not present. That check also looks for the file
  the repository just produced rather than anything matching the quantisation
  pattern: with several models in `~/models` it could otherwise size-check a
  different one and tell you a perfectly good download was incomplete.
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
- A test suite: 82 assertions. Alongside service-file preservation, uninstall
  reversal and script-versus-documentation agreement, the installer itself is
  now driven through all ten hardware paths it claims to support, against
  stubbed hardware. That means the branches nobody can safely test for real get
  exercised on every push: a mismatched NVIDIA driver that must not be
  reinstalled, an 8 GB card asked to hold a 17 GB model, SSH on a non-standard
  port, Resizable BAR switched off, an old Mesa, a missing download tool, and a
  disk too full to continue. The generated service files are also checked by
  systemd's own validator. Continuous integration runs all of it, plus
  shellcheck on two versions and a staleness check on the Part 1 guide.

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
