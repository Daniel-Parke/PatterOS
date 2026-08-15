# Local AI Budget Build, Part 2: set up local AI by hand

The no-script walkthrough, from your freshly built rig to a private AI server
and workspace.

> **About this document.** This is the companion guide to Part 2 of the video
> series, and it is the guide the installer means when it says "see the guide,
> Step 10". It does by hand exactly what
> [`scripts/install_local_ai.sh`](../scripts/install_local_ai.sh) does for you.
> This Markdown version is now the master copy, so if a step here and the
> script ever disagree, that is a bug worth reporting.

In Part 1 you built the rig and installed Linux Mint 22 (or Ubuntu 24.04). This guide takes it the rest of the way, from a fresh desktop to a working, private AI server, plus a friendly web workspace (Odysseus) to chat with it, write, take notes and more, from your desktop or your phone. Everything runs on your own machine, so nothing you type ever leaves the building.

It does, by hand, exactly what our installer script does. If you’d rather not run anyone’s script on a new machine, a sensible instinct, you can follow along here and understand every single step. Nothing below is magic; it’s a handful of ordinary commands, each explained in plain language. Take it one step at a time and you can’t really break anything: every step is safe to retry.

> Before you dive in
> Time. About 25–45 minutes of hands-on work, plus model-download time (that part is just waiting).
> You need. A working Mint 22 / Ubuntu 24.04 desktop, an internet connection, and roughly 20 GB of free disk space.
> Comfort level. None assumed. If you can copy and paste, you can do this.

> Prefer a script?
> Everything in this guide is also automated by our companion installer, `install_local_ai.sh`, one command, same result. And if you ever want to wipe this setup and start again, `uninstall_local_ai.sh` resets the machine cleanly. This manual path exists so you can see, and own, every step.

### Words you’ll meet

Don’t worry about memorising these, they’re here so nothing in the steps feels unfamiliar. You can glance back any time.

| Word | What it means (plain version) |
|---|---|
| `llama.cpp` | The engine that runs the model (the first piece above). |
| `GGUF` | The file format an AI model comes in, one big file you download. |
| Model | The AI’s “brain”, a downloaded file. Bigger ones are smarter but need more memory. |
| Token | The little chunks of text a model reads and writes, a short word, or part of one. Speed is measured in tokens per second. |
| VRAM | The memory on your graphics card. It’s the single thing that decides how big a model you can run. Memory matters more than raw speed. |
| `-ngl` | A setting that tells the engine how much of the model to put on the graphics card. More on the GPU = faster. |
| CUDA | NVIDIA’s own fast way of using the graphics card. |
| Vulkan | A universal way of using almost any graphics card (AMD, Intel, even NVIDIA). Simpler, works everywhere. |
| Router mode | A way of running the engine so it watches a whole folder of models and switches between them on the fly, no restart. |
| API | A doorway programs use to talk to each other. Your server offers the same doorway the big AI companies do, which is why so many apps will just work with it. |
| Odysseus | The web workspace you’ll chat with (the second piece above). |
| Terminal | The text window where you type commands. We open it in Step 0. |

## Part One, Get ready

### The big picture

You’re going to set up two separate pieces. Keeping them separate is what makes this flexible: you can restart, upgrade or replace either one on its own.

| The piece | What it is, in one line |
|---|---|
| The engine `(llama.cpp)` | The program that actually runs an AI model. It does the thinking, but has no nice screen, it just answers requests. |
| The workspace `(Odysseus)` | A friendly web app you open in your browser. It sends your messages to the engine and shows the replies, chat, notes, documents and more. |

And what’s actually happening in there? A model is one enormous file of numbers, its “weights”. To answer you, the engine loads that file into memory and, for every word it writes, churns through a huge pile of multiplication to predict the next one. That’s the whole trick. It’s also why memory size decides what you can run (the file has to fit), and why a graphics card, hardware built for exactly this kind of maths, makes it fast.

In everyday use you’ll open Odysseus in your browser and talk to it; the engine hums away quietly in the background. Both live entirely on your computer.

> How it all connects
> `Your apps & phone  →  Odysseus (port 7000)  →  llama.cpp (port 8020)  →  ~/models`
> Each arrow is one piece talking to the next, all on your own machine. Other programs can also talk straight to the engine, Step 10 shows how.

### Step 0, Open a terminal

The terminal is a window where you type commands instead of clicking buttons. It looks bare, but it’s just a way of telling the computer exactly what to do, and it’s how we’ll do everything here.

Open it by pressing Ctrl + Alt + T. A window appears with a blinking cursor; that’s it waiting for you.

> How to read the boxes in this guide
> Every dark shaded box below is something to run. Click into the terminal, paste the whole box, and press Enter. To paste into a terminal use Ctrl + Shift + V
> Lines that end with a backslash `\` are one long command split for readability. Lines that begin with `#` are notes to you. Dimmed boxes are examples of what you should see, not type.

## Part Two, Build the engine

### Step 1, Update the system and install the basics

First we bring the machine fully up to date, then install the tools the rest of the guide needs, the compilers that turn source code into a program, plus a few libraries. Doing it all now means no surprises later.

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential cmake git curl wget \
  pkg-config libcurl4-openssl-dev libssl-dev \
  python3-pip python3-venv python3-dev pciutils tmux \
  libvulkan-dev glslc spirv-headers vulkan-tools mesa-vulkan-drivers
```

It’ll ask for your password (the one you log in with), type it and press Enter. You won’t see anything appear as you type the password; that’s normal. The download may take a few minutes the first time.

> What did I just install?
> In plain terms: the first lines give you a C/C++ toolchain (to build the engine), Git and download tools. `python3-venv` and `tmux` are for Odysseus later. The Vulkan packages let any AMD or Intel graphics card run models without a vendor toolkit. You don’t need to remember any of this, it’s just the toolbox.

### Step 2, Find out which graphics card you have

Your graphics card (GPU) is what makes a local model fast, and different makes are set up slightly differently. This one quick check tells you which of three short paths to follow for the next two steps. Run:

```bash
lspci | grep -Ei 'vga|3d|display'
```

Look at the maker’s name in the line it prints, then pick your path from the table:

| If the name says… | You’ll follow |
|---|---|
| NVIDIA (e.g. GeForce, RTX) | Path A, NVIDIA (the fastest option) |
| AMD (e.g. Radeon RX) or Intel (Arc / built-in) | Path B, Vulkan (works on anything) |
| Nothing useful, or you just want it working | Path C, CPU only |

From here on, just follow your one path and skip the other two. AMD and Intel share Path B because Vulkan is simpler than each vendor’s own toolkit and works well. NVIDIA could use Vulkan too, but its own CUDA is faster, so NVIDIA gets its own path.

> No graphics card? That’s fine.
> Path C runs everything on your processor instead. It’s slower, but it genuinely works, and a slow answer beats no answer. You can always add a card later and switch to Path A or B.

### Step 3, Install graphics drivers and build libraries

A driver is the software that lets your system actually use the graphics card. Follow only the path you chose in Step 2.

Path A, NVIDIA

Install the driver, NVIDIA’s CUDA toolkit and a matching compiler, then restart the computer so the new driver loads:

```bash
sudo ubuntu-drivers autoinstall
sudo apt install -y nvidia-cuda-toolkit gcc-12 g++-12
sudo reboot
```

The machine will restart, that’s expected, and it’s the only reboot in this guide. When you’re back at the desktop, open a fresh terminal (Ctrl + Alt + T) and confirm the driver is alive:

```bash
nvidia-smi
```

You should see a table listing your card and its memory. If you do, the driver is working, continue to Step 4 (Path A). The `gcc-12` package is included because CUDA refuses newer compilers on Mint 22; Step 4 uses it for you automatically, so there’s nothing to configure.

Path B, AMD or Intel (Vulkan)

Good news: the driver is already built into Linux, and Step 1 already installed the Vulkan libraries. You just need to confirm your card is visible:

```bash
vulkaninfo --summary | grep deviceName
```

If your card’s name appears in the output, you’re ready, continue to Step 4 (Path B).

> Why Vulkan and not ROCm?
> If you’ve read about AMD AI setups, you may have seen “ROCm”. It’s powerful but fiddly to install. For chatting with models, Vulkan is far simpler and often just as fast. ROCm mainly pays off for advanced training later, so we keep things simple here. (That’s also why Part 1’s build guide mentions ROCm: it’s the training story, for a later video.)

Path C, CPU only

Nothing to install, the tools from Step 1 are all you need. Continue straight to Step 4 (Path C).

> Checkpoint, drivers done
> From here, the only path-specific moments left are one build command (Step 4) and one launch setting (Step 6). Everything else is identical for everyone.

### Step 4, Build the engine (llama.cpp)

“Building” just means turning the engine’s source code into a program your machine can run. We do it ourselves so it’s tuned to your exact card. This is the slowest step, a few minutes of the computer working while you wait. First, download the code (the same for everyone):

```bash
cd ~
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
```

> A note on versions
> Router mode needs a recent llama.cpp, but "latest" is not the safe choice it looks like. Until tag `b9702` (18 June 2026) the router accepted `-ngl`, `-c` and `--jinja` and then silently ignored them, so the GPU sat idle while everything looked fine. Our installer therefore pins a known-good tag. To do the same by hand, run `git checkout b10313` after cloning. If you would rather have the very latest, `git pull` gets it, just be aware you are testing it yourself.

Now compile. Run only the block for your path. The first line clears any earlier attempt, so these are always safe to re-run.

Path A, NVIDIA (CUDA)

```bash
rm -rf build   # clear any previous attempt
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DGGML_CUDA=ON -DLLAMA_CURL=ON \
  -DCMAKE_CUDA_HOST_COMPILER=$(which g++-12)
cmake --build build --config Release -j$(nproc)
```

Path B, AMD / Intel (Vulkan)

```bash
rm -rf build
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DGGML_VULKAN=ON -DLLAMA_CURL=ON
cmake --build build --config Release -j$(nproc)
```

Path C, CPU only

```bash
rm -rf build
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=ON
cmake --build build --config Release -j$(nproc)
```

When it finishes without an error, the engine is built. There’s nothing to “see” yet, we give it a model and switch it on in the next two steps.

> If the build stops with an error
> Don’t panic, it’s safe to try again. On NVIDIA, a compiler error almost always means the `g++-12` line got dropped; re-run the Path A block exactly as shown. On Vulkan, if you hit a shader error, you can simply use the Path C (CPU) block instead and everything below still works.

### Step 5, Download your first model

A “model” is the AI’s brain in a single file. We’ll keep all of them in one folder, ~/models, so the engine can switch between them later without restarting. Let’s make that folder and download a small, friendly model to start with, Gemma 4 E2B, about 2.7 GB:

```bash
mkdir -p ~/models
pip install -U --break-system-packages huggingface_hub
export PATH="$HOME/.local/bin:$PATH"
hf download unsloth/gemma-4-E2B-it-qat-GGUF \
  --include "*UD-Q4_K_XL*.gguf" --local-dir ~/models
```

That downloads one `GGUF` file into `~/models`. We picked a small model on purpose: it runs on almost anything, including CPU-only machines, so you can confirm everything works before going bigger.

Built one of the Part 1 configurations? Here’s what your card comfortably runs, remember the golden rule: a model either fits in memory or it doesn’t.

| Your card (from Part 1) | Good choices |
|---|---|
| RTX 3090 Ti or RX 7900 XTX (24 GB) | E2B, E4B, the 12B and even the 31B all fit on the card. Download any of them into `~/models` and switch between them live. |
| RTX 2070 Super (8 GB) | E2B and E4B run fully on the GPU. The 12B still works well using partial offload, see the callout in Step 6. |
| No GPU (CPU only) | Start with E2B (E4B works if you’re patient). Your 64 GB of RAM is exactly what makes this possible. |

> Bigger models, and what “UD-Q4_K_XL” means
> Got a 24 GB card? Download a bigger model into the `same` folder too, for example `unsloth/gemma-4-31B-it-qat-GGUF` or `unsloth/gemma-4-12B-it-qat-GGUF`, and you’ll be able to switch between them live in Step 7. The rule of thumb: the model file should be a bit smaller than your VRAM.
> That `UD-Q4_K_XL` in the name is the quantisation, how much the model has been compressed. It’s a well-balanced choice: much smaller than the original, with very little quality lost. You don’t need to think about it beyond picking files with that label.

Later, when you go exploring beyond Gemma: every model page on Hugging Face gives you the same three clues. The number in the name (`4B`, `12B`, `31B`…) is its size in “parameters”, bigger is smarter and hungrier. The file size listed next to each GGUF is roughly the memory it needs, so compare it to your VRAM. And models marked `-it` or `-instruct` are the ones tuned for conversation, that’s what you want for chat.

> `hf: command not found`? Close and reopen the terminal (so `~/.local/bin` joins your PATH), or run it as `~/.local/bin/hf`. The `--break-system-packages` flag looks alarming but is normal on Mint 22 / Ubuntu 24.04, it simply lets pip install this one tool for your user.

### Step 6, Start the server (router mode)

Now we switch the engine on. Rather than tying it to a single model, we point it at the whole ~/models folder. This is called router mode: the server lists every model in the folder, loads one the first time you ask for it, and can unload it again, all without ever restarting. Run only the block for your path:

Path A or B (you have a working GPU)

```bash
~/llama.cpp/build/bin/llama-server \
  --models-dir ~/models \
  --host 127.0.0.1 --port 8020 \
  --models-max 1 -ngl 999 -c 16384 --jinja
```

Path C (CPU only), the only change is -ngl 0

```bash
~/llama.cpp/build/bin/llama-server \
  --models-dir ~/models \
  --host 127.0.0.1 --port 8020 \
  --models-max 1 -ngl 0 -c 16384 --jinja
```

After a moment the terminal prints `server is listening on … :8020`. That’s your AI server, up and running. Leave this window open, closing it stops the server. (We’ll make it run quietly in the background in Step 8, so you won’t need to babysit a terminal forever.)

> What those settings mean
> `--host 127.0.0.1` keeps the server private to this computer, Step 10 shows how to share it with other apps and machines, deliberately and safely. `--models-dir ~/models` serves every model in that folder. `--models-max 1` keeps just one model in memory at a time, so asking for a different one swaps it in, safe on a single card. Do not set it to `0`: in llama.cpp that means *unlimited*, not none, so every model you ask for would stay loaded at once. `-ngl 999` puts the whole model on the GPU (use `0` for CPU). `-c 16384` is the context window, how much it can “remember” in one conversation; modest keeps memory use sane. These apply to every model the server loads.

> When a model doesn’t quite fit (8 GB cards, big models)
> `-ngl` says how many of the model’s layers go to the graphics card; the rest run from system RAM. `999` means “all of it”. If a model is bigger than your VRAM, say, the 12B on an 8 GB card, pick a middle number instead: start the server with `-ngl 20`. Out-of-memory error? Lower it. Works fine? Nudge it up. Speed lands between full-GPU and CPU, and with your 64 GB of RAM, even big models run. 1 token per second is infinitely more than 0.

### Step 7, Test it (and switch models live)

Let’s prove it works. Open a second terminal (Ctrl + Alt + T) and leave the server running in the first one. First, ask the server which models it can see:

```bash
curl http://localhost:8020/v1/models
```

```bash
# Example output (yours will differ a little):
{ "object": "list", "data": [
    { "id": "gemma-4-E2B-it-qat-UD-Q4_K_XL",
      "object": "model", ... }
] }
```

You’ll get a short list. Note the `id` of your model, it’s based on the filename, e.g. `gemma-4-E2B-it-qat-UD-Q4_K_XL`. Now use that id to ask it something. The server loads the model automatically the first time, so the very first reply may take a few seconds:

```bash
curl http://localhost:8020/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "PASTE-THE-ID-FROM-ABOVE",
    "messages": [{"role":"user","content":"Say hello in one line."}]
  }'
```

```bash
# Example output (yours will differ a little):
{ "choices": [ { "message": {
      "role": "assistant",
      "content": "Hello! How can I help you today?" }, ... } ],
  "model": "gemma-4-E2B-it-qat-UD-Q4_K_XL", ... }
```

A JSON reply with the model’s answer means you have a working local AI server. It speaks the same language as the big commercial APIs (it’s “OpenAI-compatible”), so most AI apps can use it just by pointing at this address and using any text as the API key:

```bash
http://localhost:8020/v1
```

Switching models without restarting. If you downloaded more than one model into `~/models`, just change the `"model"` field to a different id and send again, the server loads the new one (and, with `--models-max 1`, unloads the old one) on the fly. You can also do it by hand:

```bash
# Load a model into memory now
curl -X POST http://localhost:8020/models/load \
  -H "Content-Type: application/json" -d '{"model":"THE-ID"}'

# Free its memory again, no restart needed
curl -X POST http://localhost:8020/models/unload \
  -H "Content-Type: application/json" -d '{"model":"THE-ID"}'
```

> Dropped a new model file into `~/models` while the server is running? Tell it to rescan with `curl 'http://localhost:8020/v1/models?reload=1'`, again, no restart.

### Step 8, Keep it running in the background

Right now the server stops the moment you close its terminal. Let’s make it start automatically when the computer boots and quietly stay up. We do that with a “service”, a small instruction file that the system looks after for you. The block below writes that file, so you don’t have to.

First stop your manual server (press Ctrl+C in its window, or just run the kill line below), then paste the whole block:

```bash
# 1. Stop the manual server so port 8020 is free
pkill -f llama-server 2>/dev/null || true

# 2. Create the service
sudo tee /etc/systemd/system/llama.service >/dev/null <<EOF
[Unit]
Description=Local AI (llama.cpp router)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
User=$USER
WorkingDirectory=$HOME/llama.cpp
ExecStart=$HOME/llama.cpp/build/bin/llama-server \
  --models-dir $HOME/models \
  --host 127.0.0.1 --port 8020 \
  --models-max 1 -ngl 999 -c 16384 --jinja
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 3. Enable and start it
sudo systemctl daemon-reload
sudo systemctl enable --now llama.service
```

Check it’s up, and watch its live log (this is also where you’d look if anything ever misbehaves):

```bash
systemctl status llama.service
journalctl -u llama.service -f   # Ctrl+C to stop watching
```

On a CPU-only machine, change `-ngl 999` to `-ngl 0` in the service block before you paste it. Leave `--models-max 1` alone: `0` means *unlimited*, not none, so it would let every model you ask for stay in memory at once. From now on your AI server is always there, even after a restart. The two StartLimit lines are a safety net: if something is ever genuinely broken, the service stops retrying after ten quick failures instead of looping forever.

> Checkpoint, you have a private AI server
> It starts with the computer, recovers if it crashes, serves every model in `~/models`, and swaps between them live. Everything from here on builds on top of it.

## Part Three, Add the workspace

### Step 9, Install Odysseus (your AI workspace)

The engine works, but talking to it with curl commands isn’t much fun. Odysseus is the second piece: a friendly web app that gives you chat, an agent, documents, notes, email and more, all on your own machine, all free and open-source. We install it after llama.cpp so it can talk straight to the server you just set up.

1. Install it (one time)

Clone the main branch (the stable one) into its own folder and run its setup. It needs Python 3.11 or newer, which Mint 22 / Ubuntu 24.04 already include, so there’s nothing extra to install.

```bash
cd ~
git clone -b main https://github.com/odysseus-dev/odysseus.git
cd odysseus
python3 -m venv venv
source venv/bin/activate
# Let Odysseus's Cookbook find your llama-server build:
export PATH="$HOME/llama.cpp/build/bin:$PATH"
pip install -r requirements.txt
python setup.py
```

2. Start it

Launch the workspace. These same four lines also start it again any time you reopen a terminal later:

```bash
cd ~/odysseus
source venv/bin/activate
export PATH="$HOME/llama.cpp/build/bin:$PATH"
python -m uvicorn app:app --host 127.0.0.1 --port 7000
```

> Save the admin password
> The very first time it starts, Odysseus prints a one-time admin password in the terminal, copy it somewhere safe. Then open `http://localhost:7000` in your browser and sign in as `admin` with that password (you can change it later in Settings). Keep `--host 127.0.0.1` to stay on this computer only; Step 11 shows how to reach it from your phone.

3. Point it at your local model and chat

In Odysseus, open Settings, add a model, choose an OpenAI-compatible provider, and set the address to `http://localhost:8020/v1`, the server from Step 6. Use any text at all as the API key (it’s ignored locally). Odysseus will list the models from your `~/models` folder; pick one, open Chat, type “Hello” and send. A reply means everything is wired together: from now on every chat, agent run and document uses the model on your own machine, and nothing leaves the building.

4. Start it on boot (optional)

Just like the engine in Step 8, Odysseus can run as a service that starts with the computer. Press Ctrl+C in its terminal first if it’s still running from part 2, then paste the whole block:

```bash
# 1. Stop a manually started Odysseus so port 7000 is free
pkill -f 'uvicorn app:app' 2>/dev/null || true

# 2. Create the service
sudo tee /etc/systemd/system/odysseus.service >/dev/null <<EOF
[Unit]
Description=Odysseus AI workspace
After=network-online.target llama.service
Wants=network-online.target

[Service]
User=$USER
WorkingDirectory=$HOME/odysseus
Environment=PATH=$HOME/llama.cpp/build/bin:$HOME/odysseus/venv/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$HOME/odysseus/venv/bin/python -m uvicorn app:app --host 127.0.0.1 --port 7000
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 3. Enable and start it
sudo systemctl daemon-reload
sudo systemctl enable --now odysseus.service
```

Here’s a taste of what comes built in, explore at your own pace:

| Feature | What it does |
|---|---|
| Chat | Talk to your local model (or any API); adding models is simple. |
| Agent | Hand it tools and let it carry out a whole task on its own. |
| Cookbook | Scans your hardware, recommends models, downloads and serves them. |
| Deep Research | Multi-step runs that gather, read and synthesise sources into a report. |
| Compare | Test models side by side, completely blind, no bias. |
| Documents | A writing editor where the AI assists you, not the other way round. |
| Memory / Skills | Persistent memory and skills, so it gets to know you over time. |
| Email | IMAP/SMTP inbox with AI triage: auto-tag, summaries, reply drafts. |
| Notes & Tasks | Notes, a to-do list, and scheduled tasks the agent can act on. |
| Calendar | Local-first calendar with CalDAV sync (Nextcloud, Apple, Fastmail…). |
| Mobile | Responsive, and installable as an app on your phone (PWA). |

Because the engine and the workspace are separate pieces, you can always use llama.cpp on its own whenever you prefer, Odysseus is the friendly layer on top, not a requirement. (The project also ships its own service installer, `install-service.sh`, which does the same job as part 4.)

> Checkpoint, the full stack is running
> Engine + workspace, all on your own hardware: chat, documents, notes and agents, with zero data leaving the building. Everything in Part Four is an optional extra, take what you want.

## Part Four, Go further (all optional)

### Step 10, Connect other apps to your AI

Here’s the payoff of doing this properly: your server speaks the same OpenAI-style API that most AI software already understands. Code editors, agent frameworks, chat apps, if a program can talk to OpenAI, it can talk to your rig instead. Every app needs the same three settings:

| Setting | What to enter |
|---|---|
| Base URL | `http://localhost:8020/v1`  (for apps on this computer) |
| API key | Any text at all, on this computer it’s ignored. (Other machines: see below.) |
| Model | A model id from `curl http://localhost:8020/v1/models` |

A 30-second test from Python (optional)

If you write any code at all, this is all it takes, the official OpenAI library, pointed at your own machine:

```bash
pip install --break-system-packages openai
python3 - <<'PY'
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8020/v1", api_key="anything")
r = client.chat.completions.create(model="PASTE-YOUR-MODEL-ID",
    messages=[{"role": "user", "content": "Say hello in one line."}])
print(r.choices[0].message.content)
PY
```

From other machines, e.g. Cursor on your laptop

To use the rig as the AI brain for other computers in your home, three things change: open the engine’s port, let the server listen on the network, and set a real API key (it stops being optional the moment the server is reachable beyond this machine).

```bash
# 1. Open the engine's port (SSH first, so you can't lock yourself out)
sudo ufw allow OpenSSH
sudo ufw allow 8020/tcp
sudo ufw enable

# 2. Edit the service: listen on the network + require a key
sudo nano /etc/systemd/system/llama.service
```

In nano, on the `ExecStart` lines, change `--host 127.0.0.1` to `--host 0.0.0.0`, and add a key of your own choosing to the end: `--api-key pick-a-long-random-secret`. Save with Ctrl+O, Enter, exit with Ctrl+X. Then apply it and note your rig’s address:

```bash
sudo systemctl daemon-reload && sudo systemctl restart llama.service
hostname -I   # your rig's address, e.g. 192.168.1.50
```

On the other machine, give the app base URL `http://YOUR-RIG-IP:8020/v1`, your key, and the model id. In Cursor: Settings → Models, add a custom OpenAI-compatible endpoint with that base URL and key, then add your model by id. Agent frameworks (Hermes and friends) and anything else with an “OpenAI-compatible” option work exactly the same way.

> Your home network only
> Opening port `8020` shares the engine with your own network, never forward it on your router to the internet. The API key protects you from curious devices on your Wi-Fi, not from the world. (Your phone using Odysseus in Step 11 doesn’t need any of this, that’s port 7000 only.)

### Step 11, Use it from your phone

Odysseus is mobile-friendly, you can even “install” it as an app from your phone’s browser. By default it only listens on this computer; to reach it from your phone on the same home Wi-Fi, we open its port and let it listen on the network. Keep the login switched on, and never expose it to the public internet. (Already enabled the firewall in Step 10? The first block below is half done, running it again is harmless.)

1. Allow the port (SSH first, so you can’t lock yourself out)

```bash
sudo apt install -y ufw
sudo ufw allow OpenSSH
sudo ufw allow 7000/tcp
sudo ufw enable
hostname -I        # shows this PC's address, e.g. 192.168.1.50
```

2. Start Odysseus on your network

Run it bound to all interfaces instead of just this PC:

```bash
cd ~/odysseus
source venv/bin/activate
python -m uvicorn app:app --host 0.0.0.0 --port 7000
```

On your phone, open `http://YOUR-PC-IP:7000` (the address from `hostname -I`) and log in. Leave the model’s own port (`8020`) closed unless you opened it deliberately in Step 10, Odysseus is the secure, logged-in front door, and the engine stays private behind it.

Did you set Odysseus up as a boot service in Step 9, part 4? Then edit the service instead of running it by hand: `sudo nano /etc/systemd/system/odysseus.service`, change `--host 127.0.0.1` to `--host 0.0.0.0`, save, then `sudo systemctl daemon-reload && sudo systemctl restart odysseus.service`.

### Step 12, Tune the GPU power limit

This step is a nicety, not a requirement, skip it if you like. Running a model is limited mostly by memory speed, not raw wattage, so gently capping a thirsty card usually costs only a few percent of speed while noticeably cutting heat, fan noise and electricity use. Handy if the rig runs all day. We’ll use a small graphical app, so there’s no terminal tinkering with the card itself.

1. Install LACT (once)

LACT is a free, graphical power-and-fan tool for AMD, NVIDIA and Intel GPUs. On Linux Mint, the easiest route is the Software Manager (search LACT, or Flatpak). To install the latest `.deb` by hand instead, grab the Ubuntu 24.04 build from the releases page:

```bash
cd ~/Downloads
# Get the newest lact-*ubuntu-2404.deb from:
#   https://github.com/ilya-zlobintsev/LACT/releases
wget https://github.com/ilya-zlobintsev/LACT/releases/download/v0.9.0/lact-0.9.0-0.amd64.ubuntu-2404.deb -O lact.deb
sudo apt install -y ./lact.deb
# Start the background service (needed before settings will apply):
sudo systemctl enable --now lactd
```

2. Set your limit

Open LACT from your applications menu. Choose your GPU on the left, find the Power slider (sometimes labelled “Power cap” or “TDP”), drag it down to the wattage you want, for example a 450 W card to around 350 W, and click Apply.

> It remembers for you
> The first time you apply a change, LACT offers to keep your settings between restarts, accept it. Your limit is then re-applied automatically on every boot. There’s no service to write and nothing else to configure.

A couple of honest limits: AMD cards usually allow only a modest reduction (roughly 10–20% below stock), and some laptop or older GPUs don’t allow power changes at all. If the slider is greyed out, that’s the hardware’s limit, just use the lowest value it offers. CPU-only machines have no GPU power to cap, so skip this step.

## Reference

### Everyday use

Keep this page handy, it’s the handful of commands you’ll actually reach for once everything is set up.

| I want to… | Do this |
|---|---|
| See what models I have | `ls ~/models` or `curl localhost:8020/v1/models` |
| Add a new model | Download it into `~/models` (same `hf download` as Step 5), then `curl '...:8020/v1/models?reload=1'` |
| Switch model | Just use a different model id in your request, it swaps live. |
| Restart the AI server | `sudo systemctl restart llama.service` |
| Start / stop on demand | `sudo systemctl start llama.service` `sudo systemctl stop llama.service` |
| Start Odysseus again | The 4 lines in Step 9 part 2, or its boot service from part 4. |
| See the server log | `journalctl -u llama.service -f` |

### Update the engine (now and then)

We pin a known-good llama.cpp tag rather than tracking the tip. An occasional update brings new features and faster code. Whenever you feel like it:

```bash
cd ~/llama.cpp
git pull
# then re-run YOUR build block from Step 4 (Path A, B or C), and finally:
sudo systemctl restart llama.service
```

Updates are usually painless, but living on the cutting edge means a rare bad day is possible. If one ever misbehaves, `uninstall_local_ai.sh` resets everything to clean in a couple of minutes, and you set up again.

### Troubleshooting

Most first-time hiccups are in this table. Work down it, the fixes are quick, and nothing here can harm your setup.

| Symptom | Fix |
|---|---|
| Server quits with an out-of-memory error | Your model is bigger than your VRAM. Lower -ngl (e.g. 20), use a smaller model (E4B or E2B), or keep --models-max 1 so only one loads at a time. |
| `nvidia-smi` not found / no GPU used | Re-run Path A and reboot. Until the driver loads, the GPU can’t be used. |
| Build error mentioning the compiler (NVIDIA) | Make sure the build line includes the `g++-12` part. |
| Vulkan build fails | Use the Path C (CPU) build, everything else still works. |
| Reply says `model name is missing` | In router mode every request needs a `"model"` field, copy an id from `/v1/models`. |
| `hf: command not found` | Run `export PATH="$HOME/.local/bin:$PATH"`, or reopen the terminal. |
| `curl` test refused | The server window must still be open and show ‘listening’. Give a big model a minute to load. |
| Odysseus can’t see any models | Check the server is running (`systemctl status llama.service`) and the provider address ends in `/v1`. |
| Port `8020` already in use | An old server is still running: `pkill -f llama-server`, then start your service. |
| I want to wipe it all and start again | Run `uninstall_local_ai.sh` (a safe reset by default), then follow this guide, or `install_local_ai.sh`, again. |

And that’s the whole thing: update, drivers, build, run, and a workspace to use it all from. You now have a private AI setup that you put together yourself and fully understand, which means you can change any part of it with confidence. More models live at , and Odysseus’s Cookbook can find, download and serve them for you with a click. Enjoy your rig, and see you in the next part, where we put it to work.
