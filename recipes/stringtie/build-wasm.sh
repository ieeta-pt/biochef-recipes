# Build the vendored htslib as a static library. Skip the configure step
# (not committed in the bundled htslib) and write a minimal config.h that
# disables every optional compression library: only zlib is available in
# WASM via the emscripten port, so bz2/lzma/libdeflate are stripped.
cd htslib

printf "#ifndef _XOPEN_SOURCE\n#define _XOPEN_SOURCE 600\n#endif\n#define HAVE_DRAND48 1\n" > config.h

emmake make \
  CC=emcc \
  AR=emar \
  RANLIB=emranlib \
  CFLAGS="-O2 -Wall -fvisibility=hidden -sUSE_ZLIB=1 -Wno-unused-function -Wno-unused-but-set-variable" \
  CPPFLAGS="-I." \
  lib-static

cd ..

# rlink.cpp uses printCovMutex unconditionally but stringtie.cpp only
# defines it under #ifndef NOTHREADS: replace the extern declaration with an
# anonymous-struct no-op stub so the lock/unlock calls compile out.
sed -i.bak 's|extern GFastMutex printCovMutex;|struct{void lock(){}void unlock(){}}printCovMutex;|' rlink.cpp

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
