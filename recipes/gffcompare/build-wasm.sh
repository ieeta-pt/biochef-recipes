set -eo pipefail

emmake make release \
  CXX=em++ \
  LINKER=em++ \
  LDFLAGS="$EM_FLAGS -sSTACK_SIZE=8MB" \
  -j4

mkdir -p out && mv gffcompare out/gffcompare.js && mv gffcompare.wasm out/gffcompare.wasm && mv trmap out/trmap.js && mv trmap.wasm out/trmap.wasm
