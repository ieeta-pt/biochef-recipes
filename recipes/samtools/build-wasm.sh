set -eo pipefail

# htslib at the release samtools 1.24 is made against, checked by commit.
git clone --depth 1 --branch 1.24 --recurse-submodules https://github.com/samtools/htslib htslib-src
test "$(git -C htslib-src rev-parse HEAD)" = "4b705e4fada8ee2b6b15746f725ee8ac51631803"

# zlib only: no bzip2, lzma or libcurl, none of which the browser has; and no
# curses, so tview writes text or HTML rather than drawing a terminal.
cat > htslib-src/config.h <<'EOF_CONFIG'
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 600
#endif
#define HAVE_DRAND48 1
EOF_CONFIG
echo '/* zlib only, without curses */' > config.h
VARS=(CC=emcc AR=emar RANLIB=emranlib CFLAGS="-O2 -sUSE_ZLIB=1" HTSDIR=htslib-src
      HTSLIB_LIB=htslib-src/libhts.a LIBS="-lz -lm" NONCONFIGURE_OBJS= CURSES_LIB=)
emmake make -C htslib-src -j4 "${VARS[@]}" lib-static
emmake make -j4 "${VARS[@]}" LDFLAGS="-sUSE_ZLIB=1" samtools

# Linked again with EM_FLAGS. The first link wrote LDFLAGS into version.h,
# where the quotes in EM_FLAGS do not survive; version.h is not remade.
rm -f samtools samtools.wasm
emmake make "${VARS[@]}" LDFLAGS="-sUSE_ZLIB=1 -sSTACK_SIZE=8MB $EM_FLAGS" samtools

mkdir -p out
mv samtools out/samtools.js
mv samtools.wasm out/
