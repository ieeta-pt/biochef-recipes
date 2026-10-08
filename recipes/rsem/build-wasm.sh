# Break the SAMLIBS -> samtools dependency.
# RSEM only needs libhts.a, not the samtools wrapper, which does not link in WASM.
sed -i.bak 's|^\$(SAMLIBS) : \$(SAMTOOLS)/samtools$|$(SAMLIBS) :|' Makefile

# Clean previous objects built with incompatible WASM flags. This recurses into
# samtools and htslib, so it has to run before libhts.a is built.
make clean

# Build the vendored htslib as a static library.
# Disable unsupported WASM features and explicitly disable pthreads.
cd samtools-1.3/htslib-1.3

emconfigure ./configure \
  --disable-bz2 \
  --disable-lzma \
  --disable-libcurl

emmake make \
  CC=emcc \
  AR=emar \
  RANLIB=emranlib \
  CFLAGS="-O2 -fvisibility=hidden -sUSE_ZLIB=1 -sUSE_PTHREADS=0 -Wno-unused-function -Wno-unused-but-set-variable" \
  lib-static

cd ../..

# Only the tools that run on their own files. The rest of RSEM reads and writes
# a reference split across files that share a prefix, which recipes cannot
# describe yet (ieeta-pt/biochef-hub#46).
PROGRAMS="rsem-sam-validator rsem-bam2readdepth rsem-get-unique rsem-scan-for-paired-end-reads"

emmake make \
  $PROGRAMS \
  CXX=em++ \
  CXXFLAGS="-std=c++17 -O2 -Wall -I. -I./samtools-1.3/htslib-1.3 -sUSE_ZLIB=1 -sUSE_PTHREADS=0 -Wno-unused-function -Wno-deprecated-declarations -Wno-deprecated-non-prototype -Wno-c++11-narrowing -Wno-narrowing" \
  LDFLAGS="-O2 $EM_FLAGS -s USE_PTHREADS=0 -s STACK_SIZE=8388608 -s ERROR_ON_UNDEFINED_SYMBOLS=0" \
  LDLIBS="-lm -lz" \
  -j4

# Rename generated files
for b in $PROGRAMS
do
  mv "$b" "$b.js"
done
