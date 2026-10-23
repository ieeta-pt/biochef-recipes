set -e

# Build the vendored htslib as a static library with the same minimal
# config.h as the wasm build (patches/htslib-minimal-config.patch).
cd htslib

make \
  CFLAGS="-O2 -Wall -fvisibility=hidden -Wno-unused-function -Wno-unused-but-set-variable" \
  CPPFLAGS="-I." \
  lib-static

cd ..

# Build stringtie release linking against that libhts.a, single-threaded as
# in wasm.
make release \
  LIBDEFLATE= \
  LIBBZ2= \
  LIBLZMA= \
  LIBS="./htslib/libhts.a -lz -lm" \
  NOTHREADS=1

mkdir -p out && mv stringtie out/stringtie
