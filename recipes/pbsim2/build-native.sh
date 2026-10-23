set -eo pipefail

# exp, pow and tgamma are called, not folded at compile time, and no step
# is fused into an FMA, in either runtime.
BIOCHEF_MATH_FLAGS="-ffp-contract=off -fno-builtin-exp -fno-builtin-pow -fno-builtin-tgamma"

# glibc computes exp, pow and tgamma with other code than wasm, whose libc
# is musl, so the read lengths and accuracies drawn from them differ. The
# executable gets musl's, from musl 1.2.5 as emscripten 4.0.18 ships it
# (MIT licensed; exp and pow from Arm's optimized-routines), which give the
# same bits as wasm's.
BIOCHEF_LIBM=""
for f in biochef_libm/*.c; do
    gcc -O2 $BIOCHEF_MATH_FLAGS -std=c99 -include biochef_libm/biochef_musl.h -Ibiochef_libm/inc -Ibiochef_libm -c "$f" -o "${f%.c}.o"
    BIOCHEF_LIBM="$BIOCHEF_LIBM $PWD/${f%.c}.o"
done

# The hub ships a native operation as one file: the models go into the
# executable, and the one a run uses is written to its temporary directory.
{
    printf '\t.section .rodata\n'
    for m in P4C2 P5C3 P6C4 R94 R95 R103; do
        printf '\t.global biochef_model_%s\n\t.global biochef_model_%s_end\nbiochef_model_%s:\n\t.incbin "%s"\nbiochef_model_%s_end:\n\t.byte 0\n' "$m" "$m" "$m" "$PWD/data/$m.model" "$m"
    done
    printf '\t.section .note.GNU-stack,"",@progbits\n'
} > biochef_models.S
gcc -c biochef_models.S -o biochef_models.o
BIOCHEF_LIBM="$BIOCHEF_LIBM $PWD/biochef_models.o"

autoreconf -fi
./configure CXXFLAGS="-O2 $BIOCHEF_MATH_FLAGS" LIBS="$BIOCHEF_LIBM -lm"
make -j4
[ "$(nm src/pbsim | grep -c ' T \(exp\|pow\|tgamma\)$')" -eq 3 ]

mkdir -p out && cp src/pbsim out/
