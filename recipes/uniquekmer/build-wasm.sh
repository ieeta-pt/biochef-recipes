# Strip the OpenMP include (no OMP in WASM); the bare `#pragma omp parallel for`
# lines remain as ignored comments when -fopenmp is not passed.
sed -i.bak 's|#include <omp.h>||' src/genomes.cpp
# Drop -lz -lpthread -lomp and wire emcc runtime flags via LIBS.
sed -i.bak2 "s|^LIBS := -lz -lpthread.*$|LIBS := $EM_FLAGS -sSTACK_SIZE=8MB|" Makefile
emmake make CXX=em++ CXXFLAGS="-std=c++11 -O2 -I./inc -sUSE_ZLIB=1 -Wno-c++11-narrowing -Wno-narrowing -Wno-format -Wno-source-uses-openmp" -j4
mkdir -p out && mv uniquekmer out/uniquekmer.js && mv uniquekmer.wasm out/uniquekmer.wasm
