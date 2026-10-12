sed -i.bak 's|size_t front:58, bits:6, count, mask;|uint64_t front:58, bits:6; size_t count, mask;|' kdq.h

emmake make CC=emcc CFLAGS="-O2 -Wall -Wc++-compat -Wno-unused-function -sUSE_ZLIB=1" LIBS="-lm -sSTACK_SIZE=8MB  $EM_FLAGS" -j4

mv miniasm miniasm.js && mv minidot minidot.js