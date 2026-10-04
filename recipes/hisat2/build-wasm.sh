emmake make \
  hisat2-align-s \
  hisat2-build-s \
  hisat2-inspect-s \
  CXX=em++ \
  CC=emcc \
  RELEASE_FLAGS="-O2 -msimd128 -msse4.2 -std=c++11" \
  EXTRA_FLAGS="-std=c++11 $EM_FLAGS -sSTACK_SIZE=8MB" \
  NO_TBB=1 \
  -j4

for b in hisat2-align-s hisat2-build-s hisat2-inspect-s; do
  mv "$b" "$b.js"
done
