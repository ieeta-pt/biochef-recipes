emmake make CC=emcc CXX=em++ CFLAGS="-O2 -w -sUSE_ZLIB=1" LIBS="-lm $EM_FLAGS" -j4

mkdir -p out && mv t-sne out/bhtsne.js && mv t-sne.wasm out/bhtsne.wasm
