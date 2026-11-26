set -eo pipefail

ROOT="$PWD"

# exp, log and pow are called, not folded at compile time, and no step is
# fused into an FMA, in either runtime.
BIOCHEF_MATH_FLAGS="-ffp-contract=off -fno-builtin-exp -fno-builtin-log -fno-builtin-pow"

# Bifrost keeps a unitig's id and a position in one size_t, shifted by 32
# bits, and pointers or bits in one uintptr_t; kallisto writes sizes into the
# index as size_t. In wasm32 both are 32-bit, so the ids overflowed and the
# index differed. They are 64-bit here, as natively, and the index is the same
# file in both runtimes. robin_hood's and CRoaring's size_t are about memory,
# and stay, as do BioChef's own files and the entry point appended to
# src/main.cpp.
grep -rlE '\bsize_t\b' ext/bifrost/src src | grep -v 'src/robin_hood.h$\|/roaring\.\|/biochef_' | xargs sed -i -E '1,/^\/\/ The entry point of kallisto\. / s/(^|[^:_A-Za-z0-9])size_t\b/\1uint64_t/g'
grep -rlE '\buintptr_t\b' ext/bifrost/src | grep -v '/roaring\.\|/biochef_' | xargs sed -i -E 's/(^|[^:_A-Za-z0-9])uintptr_t\b/\1uint64_t/g'
sed -i -E 's/std::min\((start \+ slice, v_(blocks|unitigs)\.size\(\))\)/std::min<uint64_t>(\1)/' ext/bifrost/src/KmerCovIndex.tcc ext/bifrost/src/CompactedDBG.tcc
sed -i 's/std::min(filename_seq_in.size(), tv_nb_max_elem)/std::min<uint64_t>(filename_seq_in.size(), tv_nb_max_elem)/' ext/bifrost/src/ColoredCDBG.tcc
[ "$(cat ext/bifrost/src/KmerCovIndex.tcc ext/bifrost/src/CompactedDBG.tcc ext/bifrost/src/ColoredCDBG.tcc | grep -c 'std::min<uint64_t>')" -eq 3 ]

# bifrost calls find_package(ZLIB REQUIRED), which only resolves once the
# emscripten zlib port has been built into the sysroot.
embuilder build zlib

WASM_FLAGS="-O2 $BIOCHEF_MATH_FLAGS -sUSE_ZLIB=1 -include $ROOT/biochef_thread.h -Wno-c++11-narrowing -Wno-narrowing -Wno-c++11-narrowing-const-reference -Wno-shift-count-overflow"

mkdir -p ext/bifrost/build && cd ext/bifrost/build
emcmake cmake .. -DMAX_KMER_SIZE=32 -DENABLE_AVX2=OFF -DCOMPILATION_ARCH=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS="$WASM_FLAGS -Wno-subobject-linkage"
emmake make bifrost_static -j4
cd "$ROOT"

mkdir -p build && cd build
emcmake cmake .. -DUSE_HDF5=OFF -DUSE_BAM=OFF -DENABLE_AVX2=OFF -DCOMPILATION_ARCH=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS="$WASM_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$EM_FLAGS -sSTACK_SIZE=8MB"
emmake make kallisto -j4
cd "$ROOT"

mkdir -p out && mv build/src/kallisto.js out/kallisto.js && mv build/src/kallisto.wasm out/kallisto.wasm
