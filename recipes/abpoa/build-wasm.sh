git submodule update --init --recursive

emmake make CC=emcc CXX=em++ armv8=1 SIMD_FLAG="-D__AVX2__ -msimd128 -sUSE_ZLIB=1" -j4

emcc -O3 -DUSE_SIMDE -DSIMDE_ENABLE_NATIVE_ALIASES $EM_FLAGS src/abpoa.o -I./include ./lib/libabpoa.a -lm -lz -o abpoa.js

mkdir -p out && mv abpoa.js abpoa.wasm out/