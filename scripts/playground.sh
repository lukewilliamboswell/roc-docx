#!/bin/sh
# Build a self-contained playground with the runtime matching main.roc's platform.
set -eu

out=dist/playground
release=https://github.com/lukewilliamboswell/roc-signals/releases/download/0.4.0
mkdir -p "$out"
for asset in runtime.mjs worker.mjs; do
    curl --fail --location --silent --show-error "$release/$asset" -o "$out/$asset"
done
(
    cd "$out"
    shasum -a 256 -c <<'DIGESTS'
3cd22db8071b2cb0b05415ca82b07cf4148c34e4fa7fc73a48189b6681d53efb  runtime.mjs
b1b48c74a96b77eabd7c81bc33a0f9adc611d94c36fc8309092707ad6028993c  worker.mjs
DIGESTS
)
# roc-signals 0.4.0 documents an optimizer crash on the current nightly:
# https://github.com/roc-lang/roc/issues/12976
roc build --opt=dev --target=wasm32 --output="$out/app.wasm" playground/main.roc
cp playground/index.html playground/playground.css playground/docx-file.mjs "$out/"
