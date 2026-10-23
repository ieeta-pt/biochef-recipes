set -eo pipefail

# exp, log, pow and the others are called, not folded at compile time, and
# no step is fused into an FMA, in either runtime.
BIOCHEF_MATH_FLAGS="-ffp-contract=off -fno-builtin-exp -fno-builtin-log -fno-builtin-pow -fno-builtin-sin -fno-builtin-cos -fno-builtin-tan -fno-builtin-atan -fno-builtin-log10 -fno-builtin-log2"

# glibc computes exp, log, pow, sin, cos, tan, atan, log10 and log2 with
# other code than wasm, whose libc is musl, and the optimizers then find other
# fits. The executable gets musl's, from musl 1.2.5 as emscripten 4.0.18
# ships it (MIT licensed; exp, log and pow from Arm's optimized-routines),
# which give the same bits as wasm's.
BIOCHEF_LIBM=""
for f in biochef_libm/*.c; do
    gcc -O2 $BIOCHEF_MATH_FLAGS -std=c99 -include biochef_libm/biochef_musl.h -Ibiochef_libm/inc -Ibiochef_libm -c "$f" -o "${f%.c}.o"
    BIOCHEF_LIBM="$BIOCHEF_LIBM $PWD/${f%.c}.o"
done

# The hub ships a native operation as one file: HyPhy's batch files go
# into the executable as a tar, written to a temporary directory each run.
tar --format=ustar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf biochef_res.tar res
printf '\t.section .rodata\n\t.global biochef_res_tar\n\t.global biochef_res_tar_end\n\t.balign 16\nbiochef_res_tar:\n\t.incbin "%s"\nbiochef_res_tar_end:\n\t.byte 0\n\t.section .note.GNU-stack,"",@progbits\n' "$PWD/biochef_res.tar" > biochef_res.S
gcc -c biochef_res.S -o biochef_res.o
BIOCHEF_LIBM="$BIOCHEF_LIBM $PWD/biochef_res.o"

# The same SSE4 code as wasm, which emscripten runs on wasm SIMD, instead of
# AVX2 and FMA for this machine only, and no OpenMP threads, whose sums
# come in another order in every run.
cmake -DNOAVX=ON -DCMAKE_CXX_FLAGS="$BIOCHEF_MATH_FLAGS -DBIOCHEF_EMBEDDED_RES" -DCMAKE_CXX_STANDARD_LIBRARIES="$BIOCHEF_LIBM -lm" .
make -j4 hyphy
[ "$(nm hyphy | grep -c ' T \(exp\|log\|pow\|sin\|cos\|tan\|atan\|log10\|log2\)$')" -eq 9 ]

mkdir -p out && cp hyphy out/
