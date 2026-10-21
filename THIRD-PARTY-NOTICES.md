# Third-Party Notices

This file accompanies the Majiks Music Studio app bundle. It inventories the
third-party code named by `build-release.sh`, `pyproject.toml`, the Python
source tree, the Rust engine manifests and `engine/LICENSES.md`, and
`src/swift/Package.swift`.

The release script installs the Python packages below into the bundled
Python.framework and copies the resulting site-packages into the app. The
script does not use a complete lockfile for those installs, so package
versions other than the explicit pins can vary between builds. Cargo resolves
the Rust transitive graph from the engine lockfile; `engine/LICENSES.md` is the
engine's full-tree license policy and CI source of truth. The tables below name
the direct release inputs and the runtime libraries that the script copies or
vendors.

## Bundled Python packages

These are the packages named in the `pip install` commands in
`build-release.sh`. The `pyproject.toml` runtime dependencies are included in
this table. No `requirements*.txt` file exists under `src/python`.

| Component | License | Source |
|---|---|---|
| librosa | ISC | https://github.com/librosa/librosa |
| MLX (`mlx`) | MIT | https://github.com/ml-explore/mlx |
| `mlx-lm` | MIT | https://github.com/ml-explore/mlx-lm |
| mutagen | GPL-2.0-or-later | https://github.com/quodlibet/mutagen |
| NumPy | BSD-3-Clause (the wheel also carries MIT, 0BSD, Zlib and CC0 components) | https://github.com/numpy/numpy |
| SciPy | BSD-3-Clause (the wheel also carries OpenBLAS/LAPACK and compiler-runtime notices) | https://github.com/scipy/scipy |
| Anthropic Python SDK (`anthropic`) | MIT | https://github.com/anthropics/anthropic-sdk-python |
| OpenAI Python SDK (`openai`) | MIT | https://github.com/openai/openai-python |
| Pydantic | MIT | https://github.com/pydantic/pydantic |
| Requests | Apache-2.0 | https://github.com/psf/requests |
| SoundFile (`soundfile`) | BSD-3-Clause | https://github.com/bastibe/python-soundfile |
| Hugging Face Hub (`huggingface-hub`, pinned to 0.36.2) | Apache-2.0 | https://github.com/huggingface/huggingface_hub |
| pip | MIT | https://github.com/pypa/pip |
| Demucs (`demucs`) | MIT | https://github.com/facebookresearch/demucs |
| PyTorch (`torch`) | BSD-3-Clause | https://github.com/pytorch/pytorch |
| TorchAudio (`torchaudio`) | BSD-2-Clause | https://github.com/pytorch/audio |
| TorchVision (`torchvision`) | BSD-3-Clause | https://github.com/pytorch/vision |
| Hugging Face Diffusers (`diffusers`) | Apache-2.0 | https://github.com/huggingface/diffusers |
| Hugging Face Accelerate (`accelerate`) | Apache-2.0 | https://github.com/huggingface/accelerate |
| Transformers (pinned to 4.57.6) | Apache-2.0 | https://github.com/huggingface/transformers |
| `hangul-romanize` | MIT | https://github.com/kaniblu/hangul-romanize |
| `num2words` | LGPL-3.0-or-later | https://github.com/savoirfairelinux/num2words |
| spaCy (`spacy`) | MIT | https://github.com/explosion/spaCy |
| Cutlet (`cutlet`) | MIT | https://github.com/polm/cutlet |
| Fugashi (`fugashi`) | MIT | https://github.com/polm/fugashi |
| UniDic Lite (`unidic-lite`) | MIT | https://github.com/polm/unidic-lite |
| Hugging Face Datasets (`datasets`) | Apache-2.0 | https://github.com/huggingface/datasets |
| PyTorch Lightning (`pytorch_lightning`) | Apache-2.0 | https://github.com/Lightning-AI/pytorch-lightning |
| Matplotlib (`matplotlib`) | Matplotlib License | https://github.com/matplotlib/matplotlib |
| Click (`click`) | BSD-3-Clause | https://github.com/pallets/click |
| PEFT (`peft`) | Apache-2.0 | https://github.com/huggingface/peft |
| `py3langid` | BSD-3-Clause | https://pypi.org/project/py3langid/ |
| Pypinyin (`pypinyin`) | MIT | https://github.com/mozillazg/python-pinyin |
| TensorBoard (`tensorboard`) | Apache-2.0 | https://github.com/tensorflow/tensorboard |
| TensorBoardX (`tensorboardX`) | MIT | https://github.com/lanpa/tensorboardX |
| Einops (`einops`) | MIT | https://github.com/arogozhnikov/einops |
| Loguru (`loguru`) | MIT | https://github.com/Delgan/loguru |
| `vector-quantize-pytorch` | MIT | https://github.com/lucidrains/vector-quantize-pytorch |
| srsly | MIT | https://github.com/explosion/srsly |
| cymem | MIT | https://github.com/explosion/cymem |
| preshed | MIT | https://github.com/explosion/preshed |
| murmurhash | MIT | https://github.com/explosion/murmurhash |
| blis | MIT | https://github.com/explosion/cython-blis |
| thinc | MIT | https://github.com/explosion/thinc |
| mojimoji | MIT | https://github.com/stasm/mojimoji |
| ACE-Step 1.5 code, v0.1.6 | MIT | https://github.com/ace-step/ACE-Step-1.5/tree/v0.1.6 |

The MPS build path copies the repository's `src/python/acestep_modules`
overrides into the installed `acestep` package. Those files are ACE-Step code
overrides and are covered by the ACE-Step entry above; no ACE-Step `LICENSE`
file is vendored anywhere in this tree.

### Wheel-bundled native libraries

Some Python wheels carry native libraries in addition to their Python code.
The release script copies those wheels into the app without extracting their
native contents:

| Component | License | Source |
|---|---|---|
| libsndfile (carried by SoundFile wheels) | LGPL-2.1-or-later | https://github.com/libsndfile/libsndfile |
| OpenBLAS (carried by NumPy/SciPy wheels) | BSD-3-Clause | https://github.com/OpenMathLib/OpenBLAS |
| LAPACK (carried through OpenBLAS in NumPy/SciPy wheels) | BSD-3-Clause-Attribution | https://github.com/Reference-LAPACK/lapack |
| GCC runtime libraries where present in SciPy wheels | GPL-3.0-with-GCC-exception / LGPL-2.1-or-later for libquadmath | https://gcc.gnu.org/ |

The exact native wheel contents depend on the Python and platform wheel
selected by pip at release time. The release artifact should be checked
against its installed `*.dist-info/licenses` directories before publication.

## Bundled Python runtime and Homebrew libraries

`build-release.sh` copies the Homebrew Python 3.12 framework and conditionally
copies or vendors the following native libraries into `Contents/Frameworks/`.

| Component | License | Source |
|---|---|---|
| CPython 3.12 | PSF-2.0 | https://github.com/python/cpython |
| OpenSSL 3 (`libssl`, `libcrypto`) | Apache-2.0 | https://github.com/openssl/openssl |
| mpdecimal (`libmpdec`) | BSD-2-Clause | https://www.bytereef.org/mpdecimal/index.html |
| XZ Utils / liblzma | 0BSD | https://github.com/tukaani-project/xz |
| Zstandard (`libzstd`) | BSD-3-Clause | https://github.com/facebook/zstd |
| SQLite (`libsqlite3`, vendored by the relocation step when referenced) | Public domain | https://sqlite.org/ |

## Rust engine crates

The release invokes `src/swift/scripts/build-engine.sh`, which builds the
`agent-surface` Rust engine with the `ffi,mcp` features and links the resulting
xcframework into the app. The direct crates below are taken from the current
engine manifests and the direct-dependency section of `engine/LICENSES.md`.
Their transitive crates are statically linked and are covered by the complete
license-expression inventory in `engine/LICENSES.md` and the checked-in Cargo
lockfiles.

| Crate | License | Source |
|---|---|---|
| serde | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_json | MIT OR Apache-2.0 | https://github.com/serde-rs/json |
| thiserror | MIT OR Apache-2.0 | https://github.com/dtolnay/thiserror |
| blake3 | CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception | https://github.com/BLAKE3-team/BLAKE3 |
| regex-lite | MIT OR Apache-2.0 | https://github.com/rust-lang/regex |
| cpal | Apache-2.0 | https://github.com/rustaudio/cpal |
| crossbeam-channel | MIT OR Apache-2.0 | https://github.com/crossbeam-rs/crossbeam |
| hound | Apache-2.0 | https://github.com/ruuda/hound |
| rubato | MIT | https://github.com/HEnquist/rubato |
| libc | MIT OR Apache-2.0 | https://github.com/rust-lang/libc |
| ebur128 | MIT | https://github.com/sdroege/ebur128 |
| signalsmith-stretch | MIT | https://github.com/colinmarc/signalsmith-stretch-rs |
| coreaudio-sys | MIT | https://github.com/RustAudio/coreaudio-sys |
| rustfft | MIT OR Apache-2.0 | https://github.com/ejmahler/RustFFT |
| Symphonia and its codec/format crates | MPL-2.0 | https://github.com/pdeljanov/Symphonia |
| midir | MIT | https://github.com/Boddlnagg/midir |
| rmcp | MIT | https://github.com/modelcontextprotocol/rust-sdk |
| axum | MIT | https://github.com/tokio-rs/axum |
| tokio | MIT | https://github.com/tokio-rs/tokio |
| tower-service | MIT | https://github.com/tower-rs/tower |
| http | MIT OR Apache-2.0 | https://github.com/hyperium/http |
| UniFFI (`uniffi`) | MPL-2.0 | https://github.com/mozilla/uniffi-rs |
| reqwest | MIT OR Apache-2.0 | https://github.com/seanmonstar/reqwest |

`jsonschema` is used by the contracts-conformance test crate described in
`engine/LICENSES.md`; it is not a release-app dependency. `proptest` and
`tempfile` are likewise test-only. The Swift package manifest has no external
Swift package URLs: its `MajiksEngine.xcframework` target is a local build
product, and CoreAudio, AudioToolbox, AudioUnit, and libc++ are supplied by the
Apple SDK rather than redistributed third-party Swift packages.

### Apache-2.0 notice

For every Apache-2.0 component listed above, the applicable notice line is:

> Licensed under the Apache License, Version 2.0 (the "License"); you may not
> use this file except in compliance with the License. You may obtain a copy of
> the License at https://www.apache.org/licenses/LICENSE-2.0.

The complete Apache-2.0 text for the app and the required accompanying notice
is also shipped as `Contents/Resources/LICENSE`.

## MIT license text

The following complete MIT text is included for the requested MIT components.
The package table identifies the other MIT-licensed packages and their source
repositories.

### Demucs

Source: https://github.com/facebookresearch/demucs

Copyright (c) Meta Platforms, Inc. and affiliates.

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### ACE-Step 1.5

Source: https://github.com/ace-step/ACE-Step-1.5/tree/v0.1.6

Copyright (c) 2026 ACEStep

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Downloaded on first use

The following model artifacts are downloaded at first use and are not shipped
in the app bundle: ACE-Step 1.5 weights, Qwen3-Embedding-0.6B, Qwen3.5, the
Granite 4.0 H-Micro model, Qwen3 30B A3B, and Demucs `htdemucs` weights. Their
licenses and source links are maintained in
[`docs/MODELS_AND_LICENSES.md`](docs/MODELS_AND_LICENSES.md).

## Explicitly not bundled by the current release script

`torchcodec` is installed as a transitive dependency when applicable and then
removed by `build-release.sh`. The optional `mcp[cli]` extra in `pyproject.toml`
is not installed by the release script. Although the app contains FFmpeg
references, the current release script does not install or copy an FFmpeg
binary, so FFmpeg is not represented as a shipped component in this inventory.
