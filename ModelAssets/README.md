# Qwen3-ASR bundled model assets

The real `qwen3asr` keyboard host app and the optional `Qwen3ASRLab` target
reference the same local model resource. It is not duplicated in the source
tree or downloaded a second time:

- `Qwen3-ASR-1.7B-MLX-5bit/` from `aufklarer/Qwen3-ASR-1.7B-MLX-5bit`.

The safetensors file contains the complete 1.7B audio tower and 5-bit text
decoder. The directory is copied as a folder resource so Speech Swift can load
the audio encoder, decoder, and tokenizer without a network request. Keeping
the complete pipeline on MLX also avoids bundling a second 304 MB Core ML
encoder.

Downloaded artifact verification:

- `model.safetensors`: 2,440,468,080 bytes, SHA-256
  `4c3dd2e56a6fa3523bc996e728b7011362af317c6b0616c8d78bb1b8d9ff600e`.

The `config.json` declares the 1.7B architecture and 5-bit, group-size-64
quantization. The safetensors header contains 397 `audio_tower.*` tensors in
addition to the quantized `model.*` text-decoder tensors.
