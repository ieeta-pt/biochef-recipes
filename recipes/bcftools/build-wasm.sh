set -eo pipefail

# htslib at the release bcftools 1.24 is made against, checked by commit.
git clone --depth 1 --branch 1.24 --recurse-submodules https://github.com/samtools/htslib htslib-src
test "$(git -C htslib-src rev-parse HEAD)" = "4b705e4fada8ee2b6b15746f725ee8ac51631803"

# zlib only: no bzip2, lzma or libcurl, none of which the browser has.
cat > htslib-src/config.h <<'EOF_CONFIG'
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 600
#endif
#define HAVE_DRAND48 1
EOF_CONFIG
emmake make -C htslib-src -j4 CC=emcc AR=emar RANLIB=emranlib CFLAGS="-O2 -sUSE_ZLIB=1" LIBS="-lz -lm" NONCONFIGURE_OBJS= lib-static

# No plugins: a wasm build cannot load a shared object.
emmake make -j4 CC=emcc AR=emar RANLIB=emranlib CFLAGS="-O2 -sUSE_ZLIB=1" \
  HTSDIR=htslib-src HTSLIB_LIB=htslib-src/libhts.a PLUGINS_ENABLED=no LIBS="-lz -lm" NONCONFIGURE_OBJS= \
  LDFLAGS="-sUSE_ZLIB=1 -sSTACK_SIZE=8MB $EM_FLAGS" ALL_LIBS="-lz -lm" bcftools

mkdir -p out
mv bcftools out/bcftools.js
mv bcftools.wasm out/
