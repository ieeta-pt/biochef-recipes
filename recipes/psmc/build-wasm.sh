emmake make CC=emcc CFLAGS="-O2 -Wno-unused-function -sUSE_ZLIB=1" LIBS="-lm $EM_FLAGS -sSTACK_SIZE=8MB" -j4

cd utils && emmake make CC=emcc CFLAGS="-O2 -Wno-unused-function -sUSE_ZLIB=1" LIBS="-lm $EM_FLAGS -sSTACK_SIZE=8MB" -j4 && cd ..

mv psmc psmc.js

for b in fq2psmcfa splitfa cntcpg calD mutDiff; do mv "utils/$b" "$b.js" && mv "utils/$b.wasm" "$b.wasm"; done