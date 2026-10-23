set -eo pipefail

ROOT="$PWD"

# exp, log and pow are called, not folded at compile time, and no step is
# fused into an FMA, in either runtime.
BIOCHEF_MATH_FLAGS="-ffp-contract=off -fno-builtin-exp -fno-builtin-log -fno-builtin-pow"

# glibc computes exp, log and pow with other code than wasm, whose libc is
# musl: the fragment length model of single-end reads, and Bifrost's
# estimates of the k-mers, which size its Bloom filter, come from them. The
# executable gets musl's, from musl 1.2.5 as emscripten 4.0.18 ships it (MIT
# licensed; from Arm's optimized-routines), which give the same bits as wasm's.
BIOCHEF_LIBM=""
for f in biochef_libm/*.c; do
    gcc -O2 $BIOCHEF_MATH_FLAGS -std=c99 -include biochef_libm/biochef_musl.h -Ibiochef_libm/inc -Ibiochef_libm -c "$f" -o "${f%.c}.o"
    BIOCHEF_LIBM="$BIOCHEF_LIBM $PWD/${f%.c}.o"
done

mkdir -p ext/bifrost/build && cd ext/bifrost/build
cmake .. -DMAX_KMER_SIZE=32 -DENABLE_AVX2=OFF -DCOMPILATION_ARCH=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS="$BIOCHEF_MATH_FLAGS -Wno-subobject-linkage -Wno-return-type"
make bifrost_static -j4
cd "$ROOT"

mkdir -p build && cd build
cmake .. -DUSE_HDF5=OFF -DUSE_BAM=OFF -DENABLE_AVX2=OFF -DCOMPILATION_ARCH=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS="$BIOCHEF_MATH_FLAGS" -DCMAKE_CXX_STANDARD_LIBRARIES="$BIOCHEF_LIBM -lm"
make kallisto -j4
[ "$(nm src/kallisto | grep -c ' T \(exp\|log\|pow\)$')" -eq 3 ]
cd "$ROOT"

mkdir -p out && cp build/src/kallisto out/
