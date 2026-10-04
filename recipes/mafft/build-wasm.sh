cd core

emmake make all CC=emcc CFLAGS="-O2 -Wno-deprecated-non-prototype -Wno-implicit-function-declaration -Wno-int-conversion" LIBS="-lm $EM_FLAGS -sSTACK_SIZE=8MB" -j4

mkdir -p out

for b in pairlocalalign tbfast disttbfast dvtditr splittbfast mafft-profile mafft-distance addsingle dndfast7 f2cl; do mv "$b" "out/$b.js" && mv "$b.wasm" "out/$b.wasm"; done