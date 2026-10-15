git submodule update --init --recursive

sed -i.bak "s|^\t\tsize_t front:58, bits:6, count, mask; \\\\\$|\t\tuint64_t front:58, bits:6; \\\\\n\t\tsize_t count, mask; \\\\|" src/kdq.h

sed -i.bak "s|^#include <string.h>|#include <stdint.h>\n#include <string.h>|" src/kdq.h

sed -i.bak "s|^#if HEDLEY_HAS_ATTRIBUTE(diagnose_if)\$|#if 0 \&\& HEDLEY_HAS_ATTRIBUTE(diagnose_if)|" include/simde/simde/hedley.h

sed -i.bak2 "s|^EXTRA_FLAGS = -Wall|EXTRA_FLAGS = -sUSE_ZLIB=1 -Wall|" Makefile

emmake make CC=emcc CXX=em++ armv8=1 SIMD_FLAG="-D__AVX2__ -msimd128 -sUSE_ZLIB=1" -j4

emcc -O3 -DUSE_SIMDE -DSIMDE_ENABLE_NATIVE_ALIASES $EM_FLAGS src/abpoa.o -I./include ./lib/libabpoa.a -lm -lz -o abpoa.js

mkdir -p out && mv abpoa.js abpoa.wasm out/