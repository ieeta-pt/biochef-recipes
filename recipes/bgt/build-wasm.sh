emmake make \
  CC=emcc \
  AR=emar \
  CFLAGS="-O2 -Wall -Wc++-compat -Wno-unused-function -Wno-deprecated-non-prototype -sUSE_ZLIB=1" \
  LIBS="-L. -lbgt -lm $EM_FLAGS -sSTACK_SIZE=8MB" \
  -j4

mkdir -p out && mv bgt out/bgt.js && mv bgt.wasm out/bgt.wasm
