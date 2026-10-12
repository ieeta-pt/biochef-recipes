sed -i.bak "s|^void kt_pipeline|#ifdef __EMSCRIPTEN__\nvoid kt_pipeline(int n_threads, void *(*func)(void*, int, void*), void *shared_data, int n_steps)\n{\n\t(void)n_threads;\n\tfor (;;) {\n\t\tvoid *data = func(shared_data, 0, 0);\n\t\tif (data == 0) return;\n\t\tint step;\n\t\tfor (step = 1; step < n_steps; ++step)\n\t\t\tdata = func(shared_data, step, data);\n\t}\n}\n#else\nvoid kt_pipeline|" kthread.c

echo "#endif" >> kthread.c

emmake make CC=emcc CFLAGS="-O2 -sUSE_ZLIB=1 -msse4 -msimd128 -Wno-implicit-function-declaration -Wno-unused-function" LIBS="-lz -lm" -j4

emcc -O2 -sUSE_ZLIB=1 -msse4 -msimd128 $EM_FLAGS -sINITIAL_MEMORY=64MB kalloc.o kthread.o algo.o sys.o gfa-base.o gfa-io.o gfa-aug.o gfa-bbl.o gfa-ed.o sketch.o misc.o bseq.o options.o shortk.o miniwfa.o index.o lchain.o gchain1.o galign.o gcmisc.o map-algo.o cal_cov.o format.o gmap.o ggsimple.o ggen.o asm-call.o main.o -o minigraph.js -lz -lm
