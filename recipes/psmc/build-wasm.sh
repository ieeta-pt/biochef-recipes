set -eo pipefail

# calloc2() in khmm.h stores the row pointers as char * and the HMM code reads
# them back as double *. gcc does not exploit that aliasing violation, but
# clang at -O2 compiles hmm_new_par() into an infinite loop, so Fit PSMC Model
# never returned. -fno-strict-aliasing keeps the code as written.

emmake make CC=emcc CFLAGS="-O2 -fno-strict-aliasing -Wno-unused-function -sUSE_ZLIB=1" LIBS="-lm $EM_FLAGS -sSTACK_SIZE=8MB" -j4

cd utils && emmake make CC=emcc CFLAGS="-O2 -fno-strict-aliasing -Wno-unused-function -sUSE_ZLIB=1" LIBS="-lm $EM_FLAGS -sSTACK_SIZE=8MB" -j4 && cd ..

mv psmc psmc.js

for b in fq2psmcfa splitfa cntcpg calD mutDiff; do mv "utils/$b" "$b.js" && mv "utils/$b.wasm" "$b.wasm"; done
