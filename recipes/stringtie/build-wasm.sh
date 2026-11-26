set -e

# Build the vendored htslib as a static library, without its configure
# step; patches/htslib-minimal-config.patch gives it a minimal config.h.
cd htslib

emmake make \
  CC=emcc \
  AR=emar \
  RANLIB=emranlib \
  CFLAGS="-O2 -Wall -fvisibility=hidden -sUSE_ZLIB=1 -Wno-unused-function -Wno-unused-but-set-variable" \
  CPPFLAGS="-I." \
  lib-static

cd ..

# Build stringtie release linking against the freshly built libhts.a.
# Empty LIBDEFLATE/LIBBZ2/LIBLZMA drop those from LIBS; NOTHREADS=1 removes pthread.
emmake make release \
  CXX=em++ \
  LINKER=em++ \
  LIBDEFLATE= \
  LIBBZ2= \
  LIBLZMA= \
  LIBS="./htslib/libhts.a -lm $EM_FLAGS -sSTACK_SIZE=8MB" \
  NOTHREADS=1

mkdir -p out && mv stringtie out/stringtie.js && mv stringtie.wasm out/stringtie.wasm
