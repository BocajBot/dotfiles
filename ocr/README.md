# ocr

`mod+Shift+T` (sway, i3, Hyprland): select a screen region, copy its text to the
clipboard. QR codes and barcodes are decoded with `zbarimg`; everything else goes to a
local GLM-OCR 0.9B model served by [llama-swap](https://github.com/mostlygeek/llama-swap)
on `127.0.0.1:8080`. Replaces normcap.

## Install

```sh
ln -sf "$PWD/ocr/ocr-snip" ~/.local/bin/ocr-snip

# model (~1.4 GB)
hf download ggml-org/GLM-OCR-GGUF GLM-OCR-Q8_0.gguf mmproj-GLM-OCR-Q8_0.gguf \
    --local-dir ~/models/ocr/glm-ocr

# llama-swap: merge ocr/llama-swap-glm-ocr.yaml into ~/.config/llama-swap/config.yaml
# (the model paths are absolute — change them if your home directory differs)
mkdir -p ~/.config/systemd/user
cp ocr/llama-swap.service ~/.config/systemd/user/
systemctl --user enable --now llama-swap.service
```

Requires `llama-swap`, `llama.cpp` (`llama-server`), `zbar`, `imagemagick`, `jq`,
`curl` and `libnotify`, plus `slurp`, `grim` and `wl-clipboard` (Wayland) or `scrot`
and `xclip` (X11).

`ocr-snip IMAGE` OCRs an existing file. `OCR_API` and `OCR_MODEL` override the
endpoint and model.
