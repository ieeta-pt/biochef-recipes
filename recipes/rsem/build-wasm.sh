# Build the vendored htslib as a static library.
# Disable unsupported WASM features and explicitly disable pthreads.
cd samtools-1.3/htslib-1.3

make clean

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

# Break the SAMLIBS -> samtools dependency.
# RSEM only needs libhts.a, not the samtools wrapper.
sed -i.bak 's|^\\$(SAMLIBS) : \\$(SAMTOOLS)/samtools|\\$(SAMLIBS) :|' Makefile

# Clean previous objects built with incompatible WASM flags.
make clean

# Build RSEM binaries directly.
emmake make \
  rsem-extract-reference-transcripts \
  rsem-synthesis-reference-transcripts \
  rsem-preref \
  rsem-build-read-index \
  rsem-simulate-reads \
  rsem-parse-alignments \
  rsem-run-em \
  rsem-tbam2gbam \
  rsem-bam2wig \
  rsem-bam2readdepth \
  rsem-get-unique \
  rsem-sam-validator \
  rsem-scan-for-paired-end-reads \
  rsem-run-gibbs \
  rsem-calculate-credibility-intervals \
  CXX=em++ \
  CXXFLAGS="-std=c++17 -O2 -Wall -I. -I./samtools-1.3/htslib-1.3 -sUSE_ZLIB=1 -sUSE_PTHREADS=0 -Wno-unused-function -Wno-deprecated-declarations -Wno-deprecated-non-prototype -Wno-c++11-narrowing -Wno-narrowing" \
  LDFLAGS="$EM_FLAGS -s USE_PTHREADS=0 -s STACK_SIZE=8388608 -s ERROR_ON_UNDEFINED_SYMBOLS=0" \
  LDLIBS="-lm -lz" \
  -j4

# Rename generated files
for b in \
  rsem-extract-reference-transcripts \
  rsem-synthesis-reference-transcripts \
  rsem-preref \
  rsem-build-read-index \
  rsem-simulate-reads \
  rsem-parse-alignments \
  rsem-run-em \
  rsem-tbam2gbam \
  rsem-bam2wig \
  rsem-bam2readdepth \
  rsem-get-unique \
  rsem-sam-validator \
  rsem-scan-for-paired-end-reads \
  rsem-run-gibbs \
  rsem-calculate-credibility-intervals
do
  mv "$b" "$b.js"
done
