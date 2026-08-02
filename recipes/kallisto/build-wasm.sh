ROOT="$PWD"

rm -rf build

sed -i.bak 's|-mno-avx2||g' ext/bifrost/CMakeLists.txt

sed -i.bak 's|o\.sz_link\[i\]\.load()|o.unitig_cs_link[i].load()|' ext/bifrost/src/DataStorage.tcc

sed -i.bak '/^ExternalProject_Add(bifrost/,/^)/c\
ExternalProject_Add(bifrost PREFIX ${PROJECT_SOURCE_DIR}/ext/bifrost SOURCE_DIR ${PROJECT_SOURCE_DIR}/ext/bifrost BUILD_IN_SOURCE 1 CONFIGURE_COMMAND "" BUILD_COMMAND "" INSTALL_COMMAND "")' CMakeLists.txt

mkdir -p ext/bifrost/build && cd ext/bifrost/build

emcmake cmake .. -DMAX_KMER_SIZE=32 -DENABLE_AVX2=OFF -DCOMPILATION_ARCH=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS="-O2 -Wno-c++11-narrowing -Wno-narrowing -Wno-c++11-narrowing-const-reference -Wno-shift-count-overflow -Wno-subobject-linkage -sUSE_ZLIB=1"

emmake make bifrost_static -j4

cd "$ROOT"

mkdir -p build && cd build

emcmake cmake .. -DUSE_HDF5=OFF -DUSE_BAM=OFF -DENABLE_AVX2=OFF -DCOMPILATION_ARCH=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS="-O2 -sUSE_ZLIB=1 -Wno-c++11-narrowing -Wno-c++11-narrowing-const-reference -Wno-narrowing -Wno-shift-count-overflow" -DCMAKE_EXE_LINKER_FLAGS="$EM_FLAGS -sSTACK_SIZE=8MB"

emmake make kallisto -j4

cd "$ROOT"

mkdir -p out && mv build/src/kallisto.js out/kallisto.js && mv build/src/kallisto.wasm out/kallisto.wasm
