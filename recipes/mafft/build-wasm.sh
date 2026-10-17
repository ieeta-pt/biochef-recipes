set -eo pipefail

cd core

# Built with -Denablemultithread, MAFFT runs its distance and tree stages in
# pthread_create workers even with one thread. Without pthreads in wasm those
# workers never run and the alignment comes out wrong, so build the serial
# code path instead.
grep -qP '^\tENABLE_MULTITHREAD = -Denablemultithread' Makefile
emmake make all ENABLE_MULTITHREAD= CC=emcc CFLAGS="-O2 -Wno-deprecated-non-prototype -Wno-implicit-function-declaration -Wno-int-conversion" LIBS="-lm $EM_FLAGS -sSTACK_SIZE=8MB" -j4

mkdir -p out

for b in pairlocalalign tbfast disttbfast dvtditr splittbfast mafft-profile mafft-distance addsingle dndfast7 f2cl; do mv "$b" "out/$b.js" && mv "$b.wasm" "out/$b.wasm"; done
