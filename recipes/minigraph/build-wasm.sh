emmake make CC=emcc CFLAGS="-O2 -sUSE_ZLIB=1 -msse4 -msimd128 -Wno-implicit-function-declaration -Wno-unused-function" LIBS="-lz -lm" -j4

emcc -O2 -sUSE_ZLIB=1 -msse4 -msimd128 $EM_FLAGS -sINITIAL_MEMORY=64MB kalloc.o kthread.o algo.o sys.o gfa-base.o gfa-io.o gfa-aug.o gfa-bbl.o gfa-ed.o sketch.o misc.o bseq.o options.o shortk.o miniwfa.o index.o lchain.o gchain1.o galign.o gcmisc.o map-algo.o cal_cov.o format.o gmap.o ggsimple.o ggen.o asm-call.o main.o -o minigraph.js -lz -lm
