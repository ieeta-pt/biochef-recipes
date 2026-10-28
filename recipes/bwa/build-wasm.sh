emcc -O2 -Wall -c biochef_main.c -o biochef_main.o

emmake make CC=emcc AR=emar CFLAGS="-O3 -sUSE_ZLIB=1 -msse2 -msimd128 -Wno-unused-function -Wno-implicit-function-declaration -Dmain=bwa_main" DFLAGS=-DUSE_MALLOC_WRAPPERS LIBS="-lm -lz" -j4 bwa

emcc -O3 -msse2 -msimd128 $EM_FLAGS -sINITIAL_MEMORY=64MB bwashm.o bwase.o bwaseqio.o bwtgap.o bwtaln.o bamlite.o bwape.o kopen.o pemerge.o maxk.o bwtsw2_core.o bwtsw2_main.o bwtsw2_aux.o bwt_lite.o bwtsw2_chain.o fastmap.o bwtsw2_pair.o main.o biochef_main.o -o bwa.js -L. -lbwa -lm -lz
