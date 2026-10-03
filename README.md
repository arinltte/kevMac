<p align="center">
  <img src="public/logo.png" alt="kevMac Logo" width="64" />
  <br />
  <h1 align="center">kevMac</h1>
  <p align="center">Plain questions in. Calibrated answers out. All on your Mac.</p>
  <p align="center">
    <a href="https://github.com/arinltte/kevMac/releases/latest"><img src="https://img.shields.io/github/v/release/arinltte/kevMac?style=flat-square&color=blue" alt="Latest Release" /></a>
    <a href="https://github.com/arinltte/kevMac/blob/main/LICENSE"><img src="https://img.shields.io/github/license/arinltte/kevMac?style=flat-square&color=green" alt="License" /></a>
    <img src="https://img.shields.io/badge/macOS-14.6%2B-orange?style=flat-square" alt="macOS" />
    <img src="https://img.shields.io/badge/Apple%20Silicon-M1%2B-black?style=flat-square" alt="Apple Silicon" />
  </p>
</p>

---

**kevMac** is a lightweight macOS app for the [kev](https://github.com/jaredpalmer/kev) family of decision models. Paste any document — a customer message, a review, an article — build questions as simple forms, and get calibrated answers with animated probability bars. The app converts your form into the engine's JSON contract automatically, and turns the JSON result back into plain language. No terminal, no JSON, no button presses on a website. One setup button, and everything runs locally on your Apple Silicon Mac.

kevMac v0.3.0 runs the **[kev 1.0](https://github.com/jaredpalmer/kev/releases/tag/kev-1.0)** engine — the first versioned release of the whole Kev family, and the one that brings the **MLX backend to Apple Silicon**. The Qwen3.5 hybrid checkpoints now serve through Metal instead of crawling on slow reference kernels, documents run to 65,536 tokens with an honest refusal (never a silent truncation) past the limit, and every served checkpoint is **pinned to the upstream `@v1.0` tags** so a model can never silently change underneath you.

---

## 🏗️ Features

- **Plain text in** — Type or paste a document and build questions as simple forms. Each question picks a type: *Yes / No* (with optional "what Yes / No means" descriptions), *Multiple Choice* (named options with optional descriptions), or *Rating* (ordered levels, worst → best).
- **JSON, invisibly** — The form is converted into the kev `/v1/systemone` contract automatically. You never see or write JSON.
- **Normal text out** — Answers render as plain language — *"Returns — 83% confident"* — with animated probability bars (critically damped springs), confidence captions, and latency + token usage. A **Copy Report** button puts a plain-text summary on the clipboard.
- **Check stability** — Every multiple-choice result has a stability button: kev 1.0 re-runs the question under six shuffled option orders and reports whether the answer survives them, with the largest probability swing. Changing option order *can* change an answer — the app shows it instead of hiding it.
- **Live engine card** — The About pane shows what the engine is really doing: the pinned run (`kev-0.8b@v1.0`), the backend (`mlx`/`torch`), dtype, temperature, release date, the 65,536-token serving limit and prefix-cache hit stats.
- **Model selection, honestly labeled** — The **Model** menu lists the family: kev-0.8b (default), kev-4b, kev-9b and kev-27b, each pinned to `@v1.0` and downloadable on any Mac. The big sizes are marked **experimental** with the RAM they realistically need (9B: 48 GB+, 27B: 96–128 GB expected) — upstream has no Mac measurements at those sizes, and below the recommendation a model still loads but serves very slowly by swapping. The previous-generation kev-0.6b was removed from the app in v0.3.1; installs upgrading from older versions clean its leftover weights automatically.
- **Storage management** — Downloaded models show their disk footprint in the Model menu, and any model you're no longer serving can be removed in one click — through the Hugging Face cache's own removal tooling, so deduplicated weight blobs never orphan and nothing duplicates on disk.
- **Long documents, honestly** — States over 65,536 tokens get a clear refusal naming the token count (never a silent truncation, the pre-1.0 behavior). The editor states the *validated* context for each model — 8,192 tokens for 0.8B/4B/9B, 65,536 for 27B.
- **Same-document fast path** — kev 1.0 caches document state prefixes: re-asking questions about a document you've already analyzed is several times faster. The About pane shows the cache's hits and misses live.
- **Examples** — Three presets: **Support triage** (the shoes-arrived-late example), **News article**, and **Review rating**.
- **One-button setup** — The first launch installs everything into a dedicated `~/.kevMac` folder automatically: uv, Python 3.13, the kev-1.0 engine, and the model weights. The weights download by themselves — no button press.
- **Self-updating engine** — The engine is pinned to the kev-1.0 release tarball and stamped; installs from older app versions detect the stale snapshot and update it automatically on launch (the About pane has the button too, with live progress).

---

## Requirements

- An Apple Silicon Mac (M1 or later), macOS 14.6 or later.
- Xcode, to build and run the project.
- ~3 GB of free disk space and an internet connection for the one-time setup (more if you download larger models).

---

## 🚀 Installation

### Recommended

Download the latest `.dmg` from the [Releases](https://github.com/arinltte/kevMac/releases/latest) page, open it, and drag **kevMac** to your Applications folder.

### Gatekeeper

If macOS blocks the app on first launch, run the following in Terminal:

```bash
xattr -rd com.apple.quarantine /Applications/kevMac.app
```

### Build & run

```bash
git clone https://github.com/arinltte/kevMac.git
cd kevMac
open kevMac.xcodeproj
```

Press **Run** in Xcode. On first launch, the setup wizard appears.

### One-time setup

Press **Start Setup** — everything happens automatically, in this order:

| Step | What happens |
| --- | --- |
| 1 | Checks for `uv` (installs it via Homebrew if missing) |
| 2 | Fetches the kev engine — pinned to the **kev-1.0 release tarball** (no git needed — macOS `curl`), stamped into `.engine-tag` |
| 3 | Installs **Python 3.13** via uv — pinned explicitly, because torch ships no wheels for 3.14 |
| 4 | Creates the virtual environment and installs the engine dependencies (`uv sync --extra serve` — picks up **mlx-lm** automatically on Apple Silicon) |
| 5 | Downloads the **kev-0.8b@v1.0** checkpoint and its pinned **Qwen3.5-0.8B-Base** base model (~1.6 GB) — no button press |

The wizard skips any step that is already done. Installs from app versions before v0.3.0 find a pre-1.0 engine snapshot on disk; kevMac detects the stale stamp and updates the engine on launch (preserving the Python environment and downloaded weights), then re-syncs the dependencies so the MLX backend arrives — that update is what makes the Qwen3.5 models fast on a Mac.

---

## Getting Started

1. Press **Start Setup** and wait for **Engine ready** in the results pane (it now names the backend — `Engine ready · kev-0.8b · mlx`).
2. Paste a document into the **Document** field — the Support triage example is prefilled on first launch.
3. Edit the questions: pick a type, fill in the instructions, add or remove options with the **+ / −** buttons.
4. Press **Analyze** (or **⌘↵**) — the answers appear as animated cards with probability bars.
5. On a multiple-choice answer, press **Check stability** to see whether the pick survives shuffled option orders.
6. Press **Copy Report** to put a plain-text summary on the clipboard.

---

## ⚙️ Question types

| Type | What it answers | Form fields |
| --- | --- | --- |
| Yes / No | A yes/no question — shown as **Yes** or **No** with a certainty percentage | Instructions + optional "Yes means" / "No means" |
| Multiple Choice | Picks one option — shown as the option name with a confidence caption and a probability bar per option, plus a **Check stability** action | Instructions + named options (with optional descriptions) |
| Rating | An ordered scale — shown as the nearest level with the expected value (e.g. "expected 1.0 of 3") | Instructions + ordered levels (worst → best) |

---

## 📊 Tested

Measured on a MacBook Pro (M4-class, 16 GB), kev 1.0 engine, MLX backend, bf16 — the same six-question support-triage request, first (cold) and repeated (prefix-cached) passes:

| Model | Cold | Cached | Notes |
| --- | --- | --- | --- |
| kev-0.8b | 520 ms | 221–263 ms | peak ~2 GB RAM; also verified: 20k- and 40k-token documents served, 70k-token document refused with a named-count 422 |
| kev-4b | 1.79 s | 1.55 s | ~10 GB footprint while serving — workable on 16 GB, comfortable on 32 GB |
| kev-9b | 133 s (warmup) / 155 s (analysis) | — | loads via memory-mapped weights but every pass swap-thrashes: 11 GB of swap on a 16 GB Mac. Functional, not practical at that size — marked experimental, with the RAM recommendation in the Model menu |

The reference Apple Silicon numbers from upstream's release (M5, 32 GB): kev-0.8b **149 ms** new / **28 ms** cached; kev-4b **721 ms** / **136 ms**; a 65,000-token document reads at a 13.0 GB peak on kev-4b (84.5 s new / 716 ms cached). The pre-kev-1.0 story — Qwen3.5 DeltaNet kernels with no MPS implementation falling back to reference kernels — is gone: the hybrid checkpoints serve through MLX automatically, and `/v1/models` reports the active backend so you can see it.

The 9B/27B rows are why the picker marks them experimental and names the RAM they need: the 9B did not fit a 32 GB M5 in upstream's own measurements, and the 27B's 51 GB of bf16 weights are expected (not yet measured) to need a 96–128 GB Mac. Both stay downloadable and selectable — a user with the RAM should have them — the app just refuses to pretend the caveat isn't there.

---

## 📂 Data & Privacy

**kevMac** installs the following locally and transmits **nothing** during use — no telemetry, no analytics, no background network calls (the only network traffic is the one-time setup's downloads, the engine-update fetch, and the optional app-update check).

| Location | Contents |
| --- | --- |
| `~/.kevMac/kev/` | The kev 1.0 engine repository and its Python virtual environment (`.engine-tag` records the release) |
| `~/.kevMac/Cache/` | Downloaded model weights — content-deduplicated by the Hugging Face cache; the Model menu removes models you no longer use through the cache's own tooling |
| `~/.kevMac/Python/` | The uv-managed Python 3.13 interpreter |
| `~/.kevMac/uv-cache/` | uv's package cache |
| `~/.kevMac/Temp/` | Scratch space |

Nothing is installed outside `~/.kevMac`. To remove everything and start fresh:

```bash
rm -rf ~/.kevMac
```

---

## Switching models

The **Model** menu in the toolbar lists every supported checkpoint, pinned to the Kev 1.0 Hub tags. Models already downloaded say so, the rest show their download size; choosing one downloads it on demand, then the engine restarts on it automatically. A **Downloaded models** section shows each model's disk footprint and removes any model you're no longer serving — kevMac never leaves unused weights duplicated on disk.

| Model | Base | Pinned | Validated context | New-source accuracy | Download | Runs on |
| --- | --- | --- | --- | --- | --- | --- |
| `kev-0.8b` *(default)* | Qwen3.5-0.8B-Base | `@v1.0` | 8,192 | 0.697 (index 23.3) | ~1.6 GB | any Apple Silicon Mac |
| `kev-4b` | Qwen3.5-4B-Base | `@v1.0` | 8,192 | 0.838 (index 38.0) | ~8 GB | 32 GB Mac recommended |
| `kev-9b` *(experimental)* | Qwen3.5-9B-Base | `@v1.0` | 8,192 | 0.852 (index 41.0) | ~18 GB | 48 GB+ Mac recommended |
| `kev-27b` *(experimental)* | Qwen3.8-27B, full bf16 weights | `@v1.0` | 65,536 | 0.889 (index 52.3) | ~51 GB | expected 96–128 GB Mac |

Notes from the Kev 1.0 cards worth knowing before you pick: kev-0.8b is below chance on tool-call routing (When2Call 0.133) and date arithmetic is weak below 27B; kev-9b's v2 test margins are called optimistic upstream; kev-27b v2 is *worse and overconfident on long contracts* than its v1 (upstream suggests `@v1-lora` for contract review); and the served probabilities are always calibrated — each model's fitted temperature comes from its card, visible live in the About pane. New-source accuracy is the transfer-v4 locked test — the number closest to "your own questions"; the index is the chance-corrected breadth-v1 score.

Everything serves bf16 — the Kev 1.0 default — through MLX where it pays. The kev-0.6b that v0.1.0 shipped with was retired upstream and removed from kevMac in v0.3.1: it is no longer selectable, and its leftover weights (if an older install downloaded them) are removed automatically on first launch.

---

## 🤝 Contributing

Contributions are welcome. Whether it's a bug report, a feature suggestion, a documentation improvement, or a pull request — all are appreciated.

**To contribute:**

1. Fork the repository.
2. Create a feature branch: `git checkout -b feature/your-feature-name`
3. Commit your changes with a clear message.
4. Open a pull request against `main` with a description of what you changed and why.

**To report a bug or request a feature**, open an [issue](https://github.com/arinltte/kevMac/issues). Please include your macOS version and steps to reproduce for bug reports.

---

## 📜 License

Distributed under the MIT License. See `LICENSE` for more details.

<p align="center">
  <i>Logo by GUMO · https://www.instagram.com/gumoooo._/</i>
</p>

<p align="center">
  <i>Developed by arinltte · arinltte00@gmail.com</i>
</p>
