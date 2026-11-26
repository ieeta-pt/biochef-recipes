set -eo pipefail

# Drop -lz -lpthread -lomp and wire emcc runtime flags via LIBS. The entry
# point catches the memory errors UniqueKMER does not, which needs
# -fwasm-exceptions.
sed -i "s|^LIBS := -lz -lpthread.*$|LIBS := $EM_FLAGS -sSTACK_SIZE=8MB -fwasm-exceptions|" Makefile
grep -q -- '-fwasm-exceptions$' Makefile
emmake make CXX=em++ CXXFLAGS="-std=c++11 -O2 -I./inc -include stdint.h -sUSE_ZLIB=1 -fwasm-exceptions -Wno-c++11-narrowing -Wno-narrowing -Wno-format -Wno-source-uses-openmp" -j4
mkdir -p out && mv uniquekmer out/uniquekmer.js && mv uniquekmer.wasm out/uniquekmer.wasm
