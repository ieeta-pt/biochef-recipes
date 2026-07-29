emmake make CC=emcc CFLAGS="-O2 -Wno-unused-function -msimd128 -msse4.2 -sUSE_ZLIB=1" LIBS="-lm $EM_FLAGS -sSTACK_SIZE=8MB" -j4

mkdir -p out && mv fml-asm out/fml-asm.js && mv fml-asm.wasm out/fml-asm.wasm