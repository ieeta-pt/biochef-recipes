set -eo pipefail

cd core

# BioChef runs each MAFFT binary as one operation, in a file system shared by
# the tools of a workflow. The binaries read and write their intermediate
# results under fixed names (hat2, hat3, pre...), which the mafft script
# creates, chains and deletes. This entry point, linked into every binary,
# does that part of the script's job before the binary's own main runs.
emcc -O2 -c biochef_main.c -o biochef_main.o

# Built with -Denablemultithread, MAFFT runs its distance and tree stages in
# pthread_create workers even with one thread. Without pthreads in wasm those
# workers never run and the alignment comes out wrong, so build the serial
# code path instead.
grep -qP '^\tENABLE_MULTITHREAD = -Denablemultithread' Makefile
emmake make all ENABLE_MULTITHREAD= CC=emcc CFLAGS="-O2 -Dmain=mafft_main -Dexit=biochef_exit -Wno-deprecated-non-prototype -Wno-implicit-function-declaration -Wno-int-conversion" LIBS="biochef_main.o -lm $EM_FLAGS -sSTACK_SIZE=8MB" -j4

mkdir -p out

for b in disttbfast tbfast dvtditr dndpre pairlocalalign addsingle splittbfast mafft-profile mafft-distance f2cl; do mv "$b" "out/$b.js" && mv "$b.wasm" "out/$b.wasm"; done
