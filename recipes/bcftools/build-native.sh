set -eo pipefail

# The same htslib, zlib only and without plugins, as in the wasm build.
git clone --depth 1 --branch 1.24 --recurse-submodules https://github.com/samtools/htslib htslib-src
test "$(git -C htslib-src rev-parse HEAD)" = "4b705e4fada8ee2b6b15746f725ee8ac51631803"

cat > htslib-src/config.h <<'EOF_CONFIG'
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 600
#endif
#define HAVE_DRAND48 1
EOF_CONFIG
make -C htslib-src -j4 LIBS="-lz -lm" NONCONFIGURE_OBJS= lib-static

make -j4 HTSDIR=htslib-src HTSLIB_LIB=htslib-src/libhts.a PLUGINS_ENABLED=no LIBS="-lz -lm" NONCONFIGURE_OBJS= ALL_LIBS="-lz -lm" bcftools
