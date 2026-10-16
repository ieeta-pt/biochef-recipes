set -eo pipefail

sed -i.bak '/^void kt_for(int n_threads, void (\*func)(void\*,long,int), void \*data, long n)$/{n;s/^{$/{\n#ifdef __EMSCRIPTEN__\n\tn_threads = 1;\n#endif/}' kthread.c
sed -i.bak '/^void kt_pipeline(int n_threads, void \*(\*func)(void\*, int, void\*), void \*shared_data, int n_steps)$/{n;s/^{$/{\n#ifdef __EMSCRIPTEN__\n\tfor (;;) {\n\t\tint s;\n\t\tvoid *d = func(shared_data, 0, 0);\n\t\tif (d == 0) return;\n\t\tfor (s = 1; s < n_steps; ++s) {\n\t\t\td = func(shared_data, s, d);\n\t\t\tif (d == 0 \&\& s < n_steps - 1) return;\n\t\t}\n\t}\n#endif/}' kthread.c
sed -i.bak 's/^\tworker_t w\[4\];$/&\n#ifdef __EMSCRIPTEN__\n\tis_thr = 0;\n#endif/' mrope.c
test "$(grep -c '__EMSCRIPTEN__' kthread.c)" -eq 2
test "$(grep -c '__EMSCRIPTEN__' mrope.c)" -eq 1

sed -i.bak 's/^\t\t\t\tlong int c;$/\t\t\t\tint64_t c;/; s/^\t\t\t\tunsigned long x;$/\t\t\t\tuint64_t x;/; s/^\t\t\t\tc = va_arg(ap, long);$/\t\t\t\tc = va_arg(ap, int64_t);/' io.c
sed -i.bak '/rb3_sprintf_lite(/s/(long)/(int64_t)/g' main.c search.c
sed -i.bak -E '/^\tprintf\("%ld /{s/%ld/%lld/; s/\(long\)/(long long)/}' main.c
test "$(grep -c 'int64_t c;\|uint64_t x;\|va_arg(ap, int64_t)' io.c)" -eq 3
test "$(grep -c 'rb3_sprintf_lite(.*(long)' main.c search.c | awk -F: '{s+=$2} END {print s}')" -eq 0
test "$(grep -cP '^\tprintf\("%lld ' main.c)" -eq 8

emmake make CC=emcc CFLAGS="-O2 -Wall -Wc++-compat -Wno-unused-function -sUSE_ZLIB=1" LIBS="-lm -sSTACK_SIZE=8MB $EM_FLAGS" omp=0 -j4

mkdir -p out && mv ropebwt3 out/ropebwt3.js && mv ropebwt3.wasm out/ropebwt3.wasm
