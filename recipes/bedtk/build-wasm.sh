emmake make CC=emcc CFLAGS="-O2 -sUSE_ZLIB=1 -Wno-implicit-function-declaration" LIBS="-lz" -j4

emcc -O2 $EM_FLAGS cgranges.o bedtk.o -o bedtk.js -lz

