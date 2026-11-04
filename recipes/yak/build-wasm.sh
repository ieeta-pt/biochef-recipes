emmake make CC=emcc CFLAGS="-O2 -sUSE_ZLIB=1 -Wno-implicit-function-declaration -Wno-unused-function" LIBS="-lm -lz" -j4

emcc -O2 $EM_FLAGS kthread.o bbf.o htab.o bseq.o misc.o sys.o 6gjdn.o count.o qv.o triobin.o trioeval.o inspect.o chkerr.o sexchr.o main.o -o yak.js -lm -lz