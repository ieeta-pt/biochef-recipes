set -eo pipefail

# The entry point from the patch, linked in place of bgt's own main.
emcc -O2 -Wall -c biochef_main.c -o biochef_main.o

emmake make \
  CC=emcc \
  AR=emar \
  CFLAGS="-O2 -Wall -Wc++-compat -Wno-unused-function -Wno-deprecated-non-prototype -sUSE_ZLIB=1 -Dmain=bgt_main" \
  LIBS="biochef_main.o -L. -lbgt -lm $EM_FLAGS -sSTACK_SIZE=8MB" \
  -j4

mkdir -p out && mv bgt out/bgt.js && mv bgt.wasm out/bgt.wasm
