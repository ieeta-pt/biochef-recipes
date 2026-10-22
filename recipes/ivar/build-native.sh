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

# ivar's own sources, as src/Makefile.am lists them, without autotools.
SOURCES="src/ivar.cpp src/call_consensus_pileup.cpp src/alignment.cpp src/suffix_tree.cpp src/trim_primer_quality.cpp src/remove_reads_from_amplicon.cpp src/call_variants.cpp src/primer_bed.cpp src/allele_functions.cpp src/get_masked_amplicons.cpp src/get_common_variants.cpp src/parse_gff.cpp src/ref_seq.cpp src/interval_tree.cpp"
mkdir -p bin
g++ -O2 -std=c++11 -Ihtslib-src $SOURCES htslib-src/libhts.a -lz -lm -lpthread -o bin/ivar
