set -eo pipefail

# No step is fused into an FMA, which some CPUs have and wasm has not.
FLAGS="-Wall -O2 -ffp-contract=off"

make sptree.o tsne.o t-sne.o CFLAGS="$FLAGS" CPPFLAGS="-include biochef_tsne.h"
gcc $FLAGS -I. -c biochef_main.c -o biochef_main.o
g++ sptree.o tsne.o t-sne.o biochef_main.o -o bhtsne -lm -lz
