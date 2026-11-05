set -eo pipefail

# htslib 1.24, checked by commit, with zlib only, as in the wasm build.
git clone --depth 1 --branch 1.24 --recurse-submodules https://github.com/samtools/htslib htslib-src
test "$(git -C htslib-src rev-parse HEAD)" = "4b705e4fada8ee2b6b15746f725ee8ac51631803"
cat > htslib-src/config.h <<'EOF_CONFIG'
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 600
#endif
#define HAVE_DRAND48 1
EOF_CONFIG
make -C htslib-src -j4 LIBS="-lz -lm" NONCONFIGURE_OBJS= lib-static

# viral_consensus's sources, as its Makefile lists them.
SOURCES="main.cpp common.cpp argparse.cpp count.cpp fasta.cpp primer.cpp"
mkdir -p bin
g++ -O3 -std=c++11 -Ihtslib-src $SOURCES htslib-src/libhts.a -lz -lm -lpthread -o bin/viral_consensus
