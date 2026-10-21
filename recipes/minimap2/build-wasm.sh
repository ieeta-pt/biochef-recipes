set -eo pipefail

# The wasm build has no pthreads, where pthread_create fails, and
# kt_pipeline starts its workers with it even for one thread. Under
# emscripten, kt_for runs on one thread and kt_pipeline runs its steps in
# turn, stopping as the workers do: when a step other than the last
# returns nothing.
python3 - <<'BIOCHEF_PY'
import sys

path = "kthread.c"
src = open(path).read()


def replace(old, new):
    global src
    if src.count(old) != 1:
        sys.exit(f"patch: expected one {old[:60]!r} in {path}, found {src.count(old)}")
    src = src.replace(old, new)


replace("void kt_for(int n_threads, void (*func)(void*,long,int), void *data, long n)\n{\n",
        "void kt_for(int n_threads, void (*func)(void*,long,int), void *data, long n)\n{\n"
        "#ifdef __EMSCRIPTEN__\n\tn_threads = 1;\n#endif\n")
replace("void kt_pipeline(int n_threads, void *(*func)(void*, int, void*), void *shared_data, int n_steps)\n{\n",
        "void kt_pipeline(int n_threads, void *(*func)(void*, int, void*), void *shared_data, int n_steps)\n{\n"
        "#ifdef __EMSCRIPTEN__\n"
        "\t(void)n_threads;\n"
        "\tfor (;;) {\n"
        "\t\tvoid *data = 0;\n"
        "\t\tint step;\n"
        "\t\tfor (step = 0; step < n_steps; ++step) {\n"
        "\t\t\tdata = func(shared_data, step, data);\n"
        "\t\t\tif (data == 0 && step < n_steps - 1) return;\n"
        "\t\t}\n"
        "\t}\n"
        "#endif\n")

open(path, "w").write(src)
BIOCHEF_PY

# The SSE2 ksw2 kernels, built with SSE4.1 as wasm SIMD; the CPU dispatch
# of the default build reads cpuid, which wasm does not have.
emmake make -j4 CC=emcc AR=emar sse2only=1 CFLAGS="-O2 -msse4.1 -msimd128 -sUSE_ZLIB=1" libminimap2.a main.o
emcc -O2 -msse4.1 -msimd128 -sUSE_ZLIB=1 $EM_FLAGS main.o -o minimap2.js -L. -lminimap2 -lm -lz

mkdir -p out
mv minimap2.js minimap2.wasm out/
