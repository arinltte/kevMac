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

---

## 🏗️ Features

- **Plain text in** — Type or paste a document and build questions as simple forms. Each question picks a type: *Yes / No* (with optional "what Yes / No means" descriptions), *Multiple Choice* (named options with optional descriptions), or *Rating* (ordered levels, worst → best).
- **JSON, invisibly** — The form is converted into the kev `/v1/systemone` contract automatically. You never see or write JSON.
- **Normal text out** — Answers render as plain language — *"Returns — 83% confident"* — with animated probability bars (critically damped springs), confidence captions, and latency + token usage. A **Copy Report** button puts a plain-text summary on the clipboard.
- **Add / remove everything** — Questions, choice options, and rating levels each have add and remove buttons, validated inline (a choice needs at least two named options, a rating at least two levels).
- **Model selection** — The **Model** menu in the toolbar lists every supported checkpoint. The setup installs **kev-0.8b** by default; already-downloaded models say so, and larger ones (kev-4b, kev-9b) show their download size — pick one to download it on demand, and the engine restarts on it automatically.
- **Examples** — Three presets: **Support triage** (the shoes-arrived-late example), **News article**, and **Review rating**.
- **One-button setup** — The first launch installs everything into a dedicated `~/.kevMac` folder automatically: uv, Python 3.13, the kev engine, and the model weights. The weights download by themselves — no button press.
- **Runs fully offline after setup** — The engine serves from `~/.kevMac/Cache`, starts on launch, health-checks, and warms up in the background so your first real question answers fast.

---

## Requirements

- An Apple Silicon Mac (M1 or later), macOS 14.6 or later.
- Xcode, to build and run the project.
- ~3 GB of free disk space and an internet connection for the one-time setup.

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
| 2 | Fetches the kev engine (no git needed — macOS `curl` + tarball) |
| 3 | Installs **Python 3.13** via uv — pinned explicitly, because torch ships no wheels for 3.14 |
| 4 | Creates the virtual environment and installs the engine dependencies (`uv sync --extra serve`) |
| 5 | Downloads the **kev-0.8b** adapter and its pinned **Qwen3.5-0.8B-Base** base model (~1.6 GB) — no button press |

The wizard skips any step that is already done, so updating the app (or switching models) only downloads what is missing.

---

## Getting Started

1. Press **Start Setup** and wait for **Engine ready** in the results pane.
2. Paste a document into the **Document** field — the Support triage example is prefilled on first launch.
3. Edit the questions: pick a type, fill in the instructions, add or remove options with the **+ / −** buttons.
4. Press **Analyze** (or **⌘↵**) — the answers appear as animated cards with probability bars.
5. Press **Copy Report** to put a plain-text summary on the clipboard.
6. Load a different example from the **Examples** menu in the toolbar.

---

## ⚙️ Question types

| Type | What it answers | Form fields |
| --- | --- | --- |
| Yes / No | A yes/no question — shown as **Yes** or **No** with a certainty percentage | Instructions + optional "Yes means" / "No means" |
| Multiple Choice | Picks one option — shown as the option name with a confidence caption and a probability bar per option | Instructions + named options (with optional descriptions) |
| Rating | An ordered scale — shown as the nearest level with the expected value (e.g. "expected 1.0 of 3") | Instructions + ordered levels (worst → best) |

---

## 📊 Tested

Measured on a MacBook Pro (M4, 16 GB): at steady state — the decision engine with `kev-0.6b` loaded on MPS plus the SwiftUI app — **kevMac stays under 3.5 GB of RAM** (engine ~3.4 GB, app ~75 MB). A fresh install downloads ~2.6 GB into `~/.kevMac` (Python environment ~1 GB + model weights ~1.6 GB); nothing is installed outside that folder.

Latency on the same machine, one five-question request: **kev-0.6b ~0.2 s**, **kev-0.8b ~0.9 s**. The Qwen3.5 models' DeltaNet kernels have no MPS implementation yet, so they fall back to slow reference kernels on Apple Silicon — the kev README notes an MLX backend for Qwen3.5 is the next planned change. For the lowest latency on a Mac, use kev-0.6b; for the best accuracy, use kev-0.8b or larger.

---

## 📂 Data & Privacy

**kevMac** installs the following locally and transmits **nothing** during use — no telemetry, no analytics, no background network calls (the only network traffic is the one-time setup's downloads).

| Location | Contents |
| --- | --- |
| `~/.kevMac/kev/` | The kev engine repository and its Python virtual environment |
| `~/.kevMac/Cache/` | Downloaded model weights (kev-0.8b by default, plus any model you download from the picker) |
| `~/.kevMac/Python/` | The uv-managed Python 3.13 interpreter |
| `~/.kevMac/uv-cache/` | uv's package cache |
| `~/.kevMac/Temp/` | Scratch space |

Nothing is installed outside `~/.kevMac`. To remove everything and start fresh:

```bash
rm -rf ~/.kevMac
```

---

## Switching models

The **Model** menu in the toolbar lists every supported checkpoint. The initial setup installs **kev-0.8b** by default; models already downloaded say so in the menu, and the rest show their download size — choosing one downloads it on demand, then the engine restarts on it automatically.

| Model | Base | Serves | In-distribution | Download |
|---|---|---|---|---|
| `kev-0.6b` | Qwen3-0.6B-Base | fp32, ~0.2 s | 0.801 | ~1.2 GB |
| `kev-0.8b` | Qwen3.5-0.8B-Base | bf16, ~0.9 s | 0.829 | ~1.6 GB |
| `kev-4b` | Qwen3.5-4B-Base | bf16 | 0.877 | ~8 GB |
| `kev-9b` | Qwen3.5-9B-Base | bf16, ~19 GB memory | 0.876 | ~18 GB |

`kev-0.6b` is the model v0.1.0 shipped with and stays supported — upgrades from v0.1.0 keep it working, and the default switches to `kev-0.8b` on first launch of v0.2.0. Latency figures are measured on an M4; the Qwen3.5 models are slower on Apple Silicon until the upstream MLX backend lands.

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

Distributed under the MIT License. See `LICENSE` for more information.

The decision engine is [kev](https://github.com/jaredpalmer/kev) by Jared Palmer (Apache-2.0); the model weights are on the [Hugging Face Hub](https://huggingface.co/jaredpalmer/kev-0.8b). The base models (Qwen3-0.6B-Base, Qwen3.5) carry the Qwen license.

<p align="center">
  <i>Developed by arinltte · arinltte00@gmail.com</i>
</p>
