git clone --depth 1 https://github.com/simd-everywhere/simde simde-vendor

autoreconf -fi

sed -i.bak 's|auto const \\* next_level = std::find|auto const next_level = std::find|; s|std::distance(taxonomic_fields\\.data(), next_level)|std::distance(taxonomic_fields.begin(), next_level)|' src/tax.cc

emconfigure ./configure --disable-bzip2 --disable-pdfman

emmake make -j4 CXXFLAGS="-O2 -I../simde-vendor -msimd128 -msse4.2 -sUSE_ZLIB=1 -Wno-c++11-narrowing -Wno-narrowing" LDFLAGS="-sUSE_ZLIB=1 -sALLOW_MEMORY_GROWTH=1 -sFORCE_FILESYSTEM=1 -sSTACK_SIZE=8MB -sEXPORTED_RUNTIME_METHODS=[''FS'',''callMain'']"

mkdir -p out && mv bin/vsearch out/vsearch.js && mv bin/vsearch.wasm out/vsearch.wasm