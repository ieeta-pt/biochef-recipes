set -eo pipefail

# No step is fused into an FMA.
FLAGS="-O2 -ffp-contract=off"

emcc $FLAGS -std=c99 -Wall -c biochef_math.c -o biochef_math.o
# Filtlong reports bad arguments by throwing, which wasm only catches with
# -fexceptions.
emmake make CXX=em++ CXXFLAGS="$FLAGS -Wall -fexceptions -sUSE_ZLIB=1 -include src/biochef_filtlong.h" LIB="$PWD/biochef_math.o -fexceptions $EM_FLAGS -sSTACK_SIZE=8MB" -j4

mkdir -p out && mv bin/filtlong out/filtlong.js && mv bin/filtlong.wasm out/filtlong.wasm
