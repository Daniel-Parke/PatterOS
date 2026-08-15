# Contributing to PatterOS

Contributions are welcome, whether that is a bug report, a correction to the
guides, or code.

Before anything else, the one thing to keep in mind: **the people running this
are not developers, and it is often their only computer.** A change that is
clever but leaves someone with no graphics driver is a bad change. Safety,
reversibility and honest error messages beat elegance every time.

## Reporting a bug

Open an issue and tell us:

- what you ran, and what happened
- your distribution and version (`cat /etc/os-release`)
- your graphics card (`lspci | grep -Ei 'vga|3d|display'`)
- the output, or the interesting part of it

If it is a security problem, read [SECURITY.md](SECURITY.md) first.

## Fixing the guides

The guides in `docs/` are the master copies. `docs/part-2-manual-setup-guide.md`
must always match `scripts/install_local_ai.sh`: if the script changes a port, a
flag or a model, the guide changes in the same commit. There is a test for this
(`tests/test_docs_consistency.sh`) and it runs in CI.

`docs/PatterOS_AI_Rig_BOM_and_Build_Guide.docx` is a special case. It is linked
directly from the Part 1 video, so **it must not be renamed or moved**. Correct
it with `python tools/patch_part1_docx.py`, which edits the file in place and
leaves the formatting alone.

## Changing the scripts

Everything below is enforced in CI, so you may as well run it locally first.

```bash
# Lint. Must be completely clean, including info-level findings.
shellcheck --severity=style scripts/*.sh tests/*.sh

# Parse.
for f in scripts/*.sh tests/*.sh; do bash -n "$f"; done

# Tests. The last two need root, so run them in a throwaway container.
bash tests/test_docs_consistency.sh
docker run --rm -v "$PWD:/mnt" -w /mnt ubuntu:24.04 bash tests/test_unit_preservation.sh
docker run --rm -v "$PWD:/mnt" -w /mnt ubuntu:24.04 bash tests/test_uninstall_reversal.sh
```

**Never run the installer on a machine you care about.** Use a virtual machine
or a spare rig. It installs drivers.

### Rules that are not negotiable

1. **Every component is optional.** The user chooses what gets installed, and
   can change their mind later.
2. **Models are q4-class.** Never full-precision weights. A model either fits in
   memory or it does not, and that is what makes these fit on a real card.
3. **Re-running must be safe**, and must never overwrite something the user
   edited by hand.
4. **The uninstaller reverses the installer.** If you add something that changes
   the machine, remove it there too, and record what you changed so the
   uninstaller does not have to guess.
5. **Localhost by default.** Nothing binds to the network unless the user asks.
6. **Pin third-party code.** A tag or a commit, never a moving branch.
7. **Never claim something you have not checked.** If you cannot verify a model
   name, a licence or an upstream flag from a first-party source, say so in the
   pull request rather than guessing. Several bugs fixed in v1.4 came from
   plausible assumptions about upstream behaviour that turned out to be wrong.

### Writing for people who are new to this

- Say what will happen before it happens, in plain words.
- Never ask a question the user cannot answer. Decide for them and say what you
  decided.
- Give numbers a human unit: "17 GB, and you have 380 GB free", not a byte count.
- When you refuse to do something, explain why and offer the next best thing.

### Style

- British English. Dates as DD Month YYYY.
- No em-dashes.
- Comments explain **why**, not what. The scripts are read by beginners who were
  told to read scripts before running them, so the comments are documentation.

## Commits and pull requests

- Conventional commits (`fix:`, `docs:`, `feat:`, `chore:`), with the reasoning
  in the body where it is not obvious.
- One logical change per pull request.
- Update [CHANGELOG.md](CHANGELOG.md) under "Unreleased".
- Say what you tested on. "Not tested on hardware" is a perfectly acceptable
  thing to write, and far better than leaving us to assume you did.

## Licence and branding

Code and documentation are Apache 2.0. By contributing you agree your work is
licensed under it.

The Patter names and the contents of `branding/` are **not** covered by that
licence. See [TRADEMARK.md](TRADEMARK.md). If you are forking, see
[REBRANDING.md](REBRANDING.md).
