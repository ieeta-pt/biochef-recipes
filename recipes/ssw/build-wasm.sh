set -eo pipefail

# ssw.c uses SSE2 intrinsics from emmintrin.h, which emscripten maps to
# wasm SIMD with -msse2 -msimd128.
mkdir -p out
emcc -O3 -msse2 -msimd128 -sUSE_ZLIB=1 $EM_FLAGS \
  src/main.c src/ssw.c -lm -o out/ssw.js
