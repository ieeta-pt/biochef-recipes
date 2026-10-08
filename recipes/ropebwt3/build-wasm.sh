emmake make CC=emcc CFLAGS="-O2 -Wall -Wc++-compat -Wno-unused-function -sUSE_ZLIB=1" LIBS="-lm -sSTACK_SIZE=8MB $EM_FLAGS" omp=0 -j4

mkdir -p out && mv ropebwt3 out/ropebwt3.js && mv ropebwt3.wasm out/ropebwt3.wasm