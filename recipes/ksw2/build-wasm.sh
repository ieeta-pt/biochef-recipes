set -eo pipefail

# size_t is 32 bits in wasm32. Without a band, the DP matrices take about
# qlen * tlen bytes, so two sequences of 66 kb overflow the size and the
# allocation wraps to a small buffer that the alignment then writes past.
# Compute the sizes in 64 bits and stop with a message when they do not fit,
# or when the allocation fails.
cat > ksw2_wasm_alloc.h <<'HDR'
#include <stdint.h>
#include <stdio.h>
#include "kalloc.h"
static inline void *ksw_wasm_check(void *p, uint64_t size)
{
	if (p == 0) {
		fprintf(stderr, "[ksw2] cannot allocate %llu bytes for the alignment; use a band (-w) or shorter sequences\n", (unsigned long long)size);
		exit(1);
	}
	return p;
}
static inline void *ksw_wasm_kmalloc(void *km, uint64_t size)
{
	return ksw_wasm_check(size > SIZE_MAX ? 0 : kmalloc(km, (size_t)size), size);
}
static inline void *ksw_wasm_kcalloc(void *km, uint64_t count, size_t size)
{
	return ksw_wasm_check(count * size > SIZE_MAX ? 0 : kcalloc(km, (size_t)count, size), count * size);
}
HDR
sed -i '/k[mc]alloc(km, (*(size_t)/{s/kmalloc(km,/ksw_wasm_kmalloc(km,/; s/kcalloc(km,/ksw_wasm_kcalloc(km,/; s/(size_t)/(uint64_t)/g; }' ksw2_*.c
[ "$(grep -c 'ksw_wasm_k[mc]alloc' ksw2_*.c | awk -F: '{s+=$2} END {print s}')" = 8 ]

# sse2=1 disables the upstream's `-march=native` which would emit
# host-specific SSE that wasm32 rejects; instead use -msimd128 -msse4.2
# so emcc's SSE-to-wasm-SIMD compat headers kick in.
emmake make CC=emcc CFLAGS="-O2 -Wall -Wno-unused-function -msimd128 -msse4.2 -include ksw2_wasm_alloc.h $EM_FLAGS" sse2=1 -j4

mv ksw2-test ksw2-test.js
