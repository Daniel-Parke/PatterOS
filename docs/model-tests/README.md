# Model comparison tests

Raw output from running the same task across different local models on the same
machine, so you can judge the difference yourself rather than take anyone's word
for it.

These are unedited. Nothing has been cherry-picked, and a couple of the results
are not very good, which is rather the point: the interesting question is not
"can a local model do this" but "how small can you go before it stops being
useful to you".

## Hydrogen deep research

A single Odysseus Deep Research run, same prompt, nine model and quantisation
combinations. Open any file in a browser.

**The prompt:**

> Research the most efficient methods to convert excess solar energy into
> hydrogen gas which can be stored and used later through a fuel cell in a
> complete closed loop system.
>
> This needs to be build-able in a garage with off the shelf components.

It was chosen because it is genuinely hard: it needs real technical knowledge,
it has to stay grounded in components you can actually buy, and there is plenty
of room to invent something plausible and wrong.

**What was run**, in `docs/model-tests/hydrogen-deep-research/`. Files are named
`<size>_<quant>-<model>`:

| Model | Quant | Notes |
|---|---|---|
| Gemma 4 E2B | Q4 | Both the standard and the QAT build, so you can compare them directly |
| Gemma 4 E4B | Q4 | |
| Gemma 4 12B (QAT) | Q4 | |
| Gemma 4 26B-A4B (QAT) | Q4 | Mixture of experts, 3.8B active of 25.2B |
| Qwen3.6 27B | Q4 | |
| Qwen3.6 35B-A3B | Q3 | |
| Nemotron 3 Nano 30B-A3B | Q3 and Q4 | |

## Things worth knowing before you read too much into these

Checked against first-party sources on 15 August 2026:

- **The Nemotron results should be treated with caution.** llama.cpp support for
  `Nemotron-3-Nano-30B-A3B` was
  [closed as not planned](https://github.com/ggml-org/llama.cpp/issues/18064),
  and third-party GGUF conversions have
  [hit load assertions](https://github.com/ggml-org/llama.cpp/issues/20570).
  Quantisation choice for this architecture is limited, so a poor result here
  may say more about the conversion than the model. The 4B version, which NVIDIA
  publishes as an official GGUF, is a different and much happier story.
- **Note the licence differences.** Gemma 4 is Apache 2.0, and so is Qwen3.6.
  The NVIDIA Nemotron Open Model License is permissive and allows commercial
  use, but it is a bespoke licence with an attribution requirement and an
  indemnity clause, not Apache. Qwen 3.8 needs a sentence of its own, checked
  18 August 2026: Unsloth's build states Apache 2.0 on its model card, and
  AtomicChat's states no licence at all. AtomicChat's is a quantisation of
  Apache 2.0 Qwen/Qwen3.8-27B, so the grant should carry through, but we have
  not confirmed that from the publisher and would rather say so.
- **The installer fetches Gemma 4 QAT, and on `--full` the two Qwen 3.8 27B Q4
  builds as well.** Only the E2B and E4B come down by default; the 12B, the 31B
  and both Qwens are all `--full`. The hydrogen runs above still use Qwen3.6.
  If you want to try a file the installer does not fetch, drop the GGUF into
  `~/models` and run `curl 'http://localhost:8020/v1/models?reload=1'`.
- **A bigger model is not automatically a better answer**, and a lower
  quantisation of a bigger model is not automatically better than a higher
  quantisation of a smaller one. That trade-off is most of what these files are
  for.

## Reproducing this

Install with [the Part 2 guide](../part-2-manual-setup-guide.md) or the
installer, put the models you want in `~/models`, then use Odysseus's Deep
Research with the prompt above. Same prompt, same hardware, one variable at a
time.
