# Models and licenses

This inventory records the model weights and software bundled with or fetched by
Majiks Music Studio. Sources were checked on 2026-10-21. The license for each
model or repository controls its use; this page does not add rights to training
data, trademarks, or user-provided material.

| Component | Use in the app | License | Source / note |
|---|---|---|---|
| [ACE-Step 1.5](https://huggingface.co/ACE-Step/Ace-Step1.5) — `acestep-v15-turbo`, SFT/base/XL DiT variants, 5 Hz LMs (`0.6B`, `1.7B`, `4B`), and VAE | Local music generation, editing, and audio understanding | MIT | The [ACE-Step repository](https://github.com/ace-step/ACE-Step-1.5) and model card identify the project as MIT. The model card states that generated music may be used for commercial purposes. |
| [Qwen3-Embedding-0.6B](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B) | ACE-Step text encoder (turns the prompt and lyrics into conditioning for generation) | Apache-2.0 | License shown on the Hugging Face model card. |
| [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B), distributed for MLX as [`mlx-community/Qwen3.5-4B-4bit`](https://huggingface.co/mlx-community/Qwen3.5-4B-4bit) | Parameter extraction | Apache-2.0 | The upstream Qwen model card is Apache-2.0; the MLX 4-bit page identifies the converted artifact. |
| [Granite 4.0 H-Micro 4-bit](https://huggingface.co/mlx-community/granite-4.0-h-micro-4bit) | Low-memory local chat default below 24 GB RAM | Apache-2.0 | License shown on the Hugging Face model card. |
| [Qwen3 30B A3B Instruct 2507 4-bit](https://huggingface.co/mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit) | Local chat default at 24 GB RAM and above | Apache-2.0 | License shown on the Hugging Face model card. |
| [Demucs `htdemucs`](https://github.com/facebookresearch/demucs) | Optional local stem separation | MIT | Demucs is MIT. Its weights are fetched from Meta's hub at first use; they are not redistributed by the app. |
| Majiks Music Studio source and app | The application | Apache-2.0 | See [`LICENSE`](../LICENSE). Product names, logos, and other marks remain subject to [`TRADEMARK.md`](../TRADEMARK.md) and separate trademark rights. |

The ACE-Step commercial-use statement applies to the generated music described
by its model card. It does not clear copyrighted prompts, reference audio,
lyrics, samples, or styles supplied by a user.
