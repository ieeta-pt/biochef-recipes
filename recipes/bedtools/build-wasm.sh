set -eo pipefail

# The htslib bundled with bedtools, with zlib only: no bzip2 or lzma.
cat > src/utils/htslib/config.h <<'EOF_CONFIG'
#define HAVE_FSEEKO 1
#define HAVE_DRAND48 1
EOF_CONFIG

emmake make -j4 CXX=em++ CC=emcc AR=emar RANLIB=emranlib \
  CFLAGS="-O2 -sUSE_ZLIB=1" BT_CXXFLAGS="-O2 -std=c++11 -sUSE_ZLIB=1" \
  BT_LDFLAGS="-O2 $EM_FLAGS" BT_LIBS="-lz -lm" bin/bedtools

mkdir -p out
mv bin/bedtools out/bedtools.js
mv bin/bedtools.wasm out/
