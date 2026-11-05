set -eo pipefail

# htslib 1.24, checked by commit, with zlib only: no bzip2, lzma or libcurl.
git clone --depth 1 --branch 1.24 --recurse-submodules https://github.com/samtools/htslib htslib-src
test "$(git -C htslib-src rev-parse HEAD)" = "4b705e4fada8ee2b6b15746f725ee8ac51631803"
cat > htslib-src/config.h <<'EOF_CONFIG'
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 600
#endif
#define HAVE_DRAND48 1
EOF_CONFIG
emmake make -C htslib-src -j4 CC=emcc AR=emar RANLIB=emranlib CFLAGS="-O2 -sUSE_ZLIB=1" \
  LIBS="-lz -lm" NONCONFIGURE_OBJS= lib-static

# viral_consensus's sources, as its Makefile lists them.
SOURCES="main.cpp common.cpp argparse.cpp count.cpp fasta.cpp primer.cpp"
mkdir -p out
em++ -O3 -std=c++11 -sUSE_ZLIB=1 -Ihtslib-src $EM_FLAGS \
  $SOURCES htslib-src/libhts.a -lz -lm -o out/viral_consensus.js
