emmake make CC=emcc CFLAGS="-Wall -O2 -sUSE_ZLIB=1" LIBS="-lm -sSTACK_SIZE=8MB $EM_FLAGS" -j4

mkdir -p out && mv velveth out/velveth.js && mv velveth.wasm out/velveth.wasm && mv velvetg out/velvetg.js && mv velvetg.wasm out/velvetg.wasm