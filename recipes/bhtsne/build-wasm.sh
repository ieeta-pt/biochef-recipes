set -eo pipefail

# No step is fused into an FMA, which some CPUs have and wasm has not.
FLAGS="-Wall -O2 -ffp-contract=off"

emmake make sptree.o tsne.o t-sne.o CC=emcc CXX=em++ CFLAGS="$FLAGS" CPPFLAGS="-include biochef_tsne.h"
emcc $FLAGS -sUSE_ZLIB=1 -I. -c biochef_main.c -o biochef_main.o
em++ sptree.o tsne.o t-sne.o biochef_main.o -o bhtsne.js -lm -sUSE_ZLIB=1 $EM_FLAGS

mkdir -p out && mv bhtsne.js out/bhtsne.js && mv bhtsne.wasm out/bhtsne.wasm
