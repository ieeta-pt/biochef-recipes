sed -i.bak "s|^void kt_pipeline|#ifdef __EMSCRIPTEN__\nvoid kt_pipeline(int n_threads, void *(*func)(void*, int, void*), void *shared_data, int n_steps)\n{\n\t(void)n_threads;\n\tfor (;;) {\n\t\tvoid *data = func(shared_data, 0, 0);\n\t\tif (data == 0) return;\n\t\tint step;\n\t\tfor (step = 1; step < n_steps; ++step)\n\t\t\tdata = func(shared_data, step, data);\n\t}\n}\n#else\nvoid kt_pipeline|" kthread.c

echo "#endif" >> kthread.c

sed -i.bak "s|^\tif (n_threads > 1) {$|#ifdef __EMSCRIPTEN__\n\tn_threads = 1;\n#endif\n\tif (n_threads > 1) {|" kthread.c

emmake make CC=emcc CFLAGS="-O2 -sUSE_ZLIB=1 -Wno-implicit-function-declaration -Wno-unused-function" LIBS="-lm -lz" -j4

emcc -O2 $EM_FLAGS kthread.o bbf.o htab.o bseq.o misc.o sys.o 6gjdn.o count.o qv.o triobin.o trioeval.o inspect.o chkerr.o sexchr.o main.o -o yak.js -lm -lz