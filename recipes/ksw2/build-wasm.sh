# sse2=1 disables the upstream's `-march=native` which would emit
# host-specific SSE that wasm32 rejects; instead use -msimd128 -msse4.2
# so emcc's SSE-to-wasm-SIMD compat headers kick in.
emmake make CC=emcc CFLAGS="-O2 -Wall -Wno-unused-function -msimd128 -msse4.2 $EM_FLAGS" sse2=1 -j4

mv ksw2-test ksw2-test.js