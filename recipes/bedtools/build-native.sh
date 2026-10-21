set -eo pipefail

# The htslib bundled with bedtools, with zlib only, as in the wasm build.
cat > src/utils/htslib/config.h <<'EOF_CONFIG'
#define HAVE_FSEEKO 1
#define HAVE_DRAND48 1
EOF_CONFIG

make -j4 CFLAGS="-Wall -O2" BT_CXXFLAGS="-Wall -O2 -std=c++11" BT_LIBS="-lz -lm -lpthread" bin/bedtools
