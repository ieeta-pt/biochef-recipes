emmake make \
  CXX=em++ \
  CXXFLAGS="-Wall -Wextra -pedantic -O2 -sUSE_ZLIB=1" \
  LIB="$EM_FLAGS -sSTACK_SIZE=8MB" \
  -j4

mkdir -p out && mv bin/filtlong out/filtlong.js && mv bin/filtlong.wasm out/filtlong.wasm
