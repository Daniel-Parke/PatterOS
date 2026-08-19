# Security policy

PatterOS runs as root, on other people's computers, and in many cases on the
only computer they own. That shapes everything below.

## Reporting a problem

Please report privately first, so it can be fixed before it is public:

- Open a [security advisory](https://github.com/Daniel-Parke/PatterOS/security/advisories/new)
  on this repository, or
- open a normal issue **only if** the problem is already public knowledge.

Tell us what you found, how to reproduce it, and what an attacker could actually
do with it. A rough report is far better than no report. You do not need a proof
of concept.

Expect an acknowledgement within a few days. This is a small project, not a
company with a rota, so please be patient rather than assuming silence means
indifference.

## What counts as a security problem here

More than you might expect, because of who uses this:

- Anything that could run code the user did not intend to run, including a
  dependency address that could be taken over.
- Anything that exposes the machine to the network when the user did not ask
  for it, or that stops the firewall protecting them.
- Anything that could lock a user out of their own machine.
- Anything that leaks a credential into a log, a terminal history or a file
  other users can read.
- Anything that could leave a machine unbootable or without working graphics.

That last one matters. Breaking somebody's desktop is, for this audience, as
serious as a remote exploit.

## What PatterOS does to keep you safe

- **Everything listens on this computer only.** The model server and the
  workspace bind to `127.0.0.1`. Opening them to your network is a deliberate,
  documented step you take yourself.
- **Third-party code is pinned.** llama.cpp is built from a fixed tag and
  Odysseus from a fixed commit, so everyone installs the same thing and we can
  say what "the same thing" is.
- **Nothing is installed unless you choose it.** Every component is optional.
- **The uninstaller is expected to reverse the installer**, and there is a test
  that proves it, including not removing a user group you already belonged to.

## What PatterOS installs that you should know about

PatterOS sets up other people's software. Three points worth reading before you
run it:

- **Odysseus** includes an AI agent that can run commands, read files and access
  email. Its own threat model is candid that it is not sandboxed and can be
  influenced by content it reads. PatterOS keeps it on `127.0.0.1`. Do not
  expose it to the internet.
- **llama.cpp** is built from source on your machine. The pinned tag is recorded
  in the installer so you can check it yourself.
- **Model weights are not pinned the way the code is.** llama.cpp gets a tag and
  Odysseus gets a commit. Models are asked for by repository and filename, so
  what arrives is whatever that repository holds on the day you run the script.
  The size check afterwards catches a download that was cut short. It does not
  catch a file that changed. The repositories are named in the installer and in
  [NOTICE](NOTICE), so you can look before you fetch, and you can always skip
  the download entirely with `--no-models` and add your own files later.

## Supported versions

The latest release on `main` is the supported one. This is a small project and
there is no long-term support branch.

## Please do not

- Report findings from an automated scanner without checking them first.
- Test against machines that are not yours.
