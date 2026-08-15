## What this changes

<!-- One or two sentences. What was wrong, or what is now possible? -->

## Why

<!-- The reasoning, if it is not obvious from the change itself. -->

## How it was tested

<!--
Be honest. "Not tested on hardware" is a perfectly acceptable answer and much
more useful than leaving us to assume you did.
-->

- [ ] `shellcheck --severity=style scripts/*.sh tests/*.sh` is clean
- [ ] `bash tests/test_docs_consistency.sh` passes
- [ ] The container tests pass (`test_unit_preservation.sh`, `test_uninstall_reversal.sh`)
- [ ] Ran it on real hardware. If so, which GPU?

## Checklist

- [ ] If a flag, port or model changed, the guide in `docs/` changed too
- [ ] If it changes the machine, the uninstaller reverses it
- [ ] It is safe to run twice
- [ ] Anything new is optional
- [ ] Any third-party code is pinned to a tag or commit
- [ ] CHANGELOG.md updated
- [ ] Any upstream fact (model name, licence, flag) was checked against a
      first-party source, or is flagged below as unverified

## Anything you could not verify

<!-- Say so here rather than leaving it implied. -->
