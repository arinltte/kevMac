import Foundation

/// The Python weight-download script, shared by `SetupManager` (first-run setup) and
/// `KevManager` (on-demand downloads). It mirrors upstream's loader rule (`kev/checkpoint.py`):
///
/// - **LoRA checkpoints** (0.6b/0.8b/4b/9b): download the adapter, then the base at the exact
///   `base_revision` `head.pt` names — that is what the engine loads offline.
/// - **Full-weight checkpoints** (27b): no `adapter_config.json` — the whole bf16 backbone ships
///   inside the checkpoint. Downloading the base's weights too would double the disk cost for
///   weights the loader never reads from the Hub; only the tokenizer bits come from the base.
///
/// Pinning: the adapter is fetched at the same `@v1.0` revision the server will later request
/// (`--run repo@v1.0` under `HF_HUB_OFFLINE=1`), so offline revision resolution works. The
/// engine passes the pin only once its snapshot understands `@revision` (the pre-kev-1.0
/// snapshot's `--run` regex rejects it and would silently fall back to `runs/smoke`), so the
/// caller decides `pinned` and must keep download and serve in agreement.
enum ModelDownload {
    static func script(for model: KevModel, pinned: Bool) -> String {
        // `None` when unpinned (kev-0.6b, or a pre-1.0 engine that cannot serve pins); 'v1.0' otherwise
        let revisionLiteral = pinned && model.pin != nil ? "'\(model.pin ?? "v1.0")'" : "None"
        return """
        import os
        import sys

        os.environ['HF_HOME'] = sys.argv[1]

        from huggingface_hub import snapshot_download

        repo = '\(model.rawValue)'
        revision = \(revisionLiteral)

        print(f"Downloading {repo}{'@' + revision if revision else ''} checkpoint and head weights...")
        adapter = snapshot_download(repo, revision=revision)

        import torch
        meta = torch.load(os.path.join(adapter, 'head.pt'), map_location='cpu')
        base = meta.get('base', '\(model.base)')
        base_revision = meta.get('base_revision')

        if not os.path.exists(os.path.join(adapter, 'adapter_config.json')):
            # Full-weight checkpoint (kev-27b): the backbone is inside the checkpoint itself.
            # Only the tokenizer bits come from the base repo — fetching its weights too would
            # double the disk cost for files the loader never reads.
            print(f"Downloading the tokenizer bits of the base model {base}...")
            snapshot_download(base, revision=base_revision, allow_patterns=['*.json', '*.txt', '*.jinja', '*.model'])
        else:
            print(f"Downloading the base model {base}...")
            snapshot_download(base, revision=base_revision)

        print("Model weights downloaded successfully.")
        """
    }
}
