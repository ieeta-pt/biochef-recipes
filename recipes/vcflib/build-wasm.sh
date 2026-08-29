git submodule update --init --recursive

sed -i.bak "s|^find_package(BZip2 REQUIRED).*|if(NOT EMSCRIPTEN)\nfind_package(BZip2 REQUIRED)\nendif()|" CMakeLists.txt
sed -i.bak "s|^find_package(LibLZMA REQUIRED).*|if(NOT EMSCRIPTEN)\nfind_package(LibLZMA REQUIRED)\nendif()|" CMakeLists.txt
sed -i.bak "s|^find_package(ZLIB REQUIRED).*|if(NOT EMSCRIPTEN)\nfind_package(ZLIB REQUIRED)\nendif()|" CMakeLists.txt
sed -i.bak "s|^set_package_properties(ZLIB PROPERTIES TYPE REQUIRED)$|if(NOT EMSCRIPTEN)\nset_package_properties(ZLIB PROPERTIES TYPE REQUIRED)\nendif()|" CMakeLists.txt
sed -i.bak 's|"-march=native -D_FILE_OFFSET_BITS=64"|"-D_FILE_OFFSET_BITS=64"|' CMakeLists.txt
sed -i.bak "s|^if (NOT BUILD_STATIC) # only when not building static$|if (NOT BUILD_STATIC AND NOT EMSCRIPTEN AND pybind11_FOUND) # only when not building static|" CMakeLists.txt
sed -i.bak "s|set(flags \"-O2 -g -fPIC\")|set(flags \"-O2 -g -sUSE_ZLIB=1 -fPIC\")|" CMakeLists.txt
sed -i.bak "s|CONFIGURE_COMMAND ./configure --disable-s3|CONFIGURE_COMMAND emconfigure ./configure --disable-s3 --disable-bz2 --disable-lzma --disable-libcurl --disable-plugins CFLAGS=-sUSE_ZLIB=1 LDFLAGS=-sUSE_ZLIB=1|" CMakeLists.txt
sed -i.bak "s|BUILD_COMMAND \$(MAKE) CFLAGS=\${flags} lib-static|BUILD_COMMAND emmake make CFLAGS=\${flags} lib-static|" CMakeLists.txt
sed -i.bak "s|set(vcflib_LIBS curl deflate)|set(vcflib_LIBS)|" CMakeLists.txt
sed -i.bak "/^  lzma\$/d" CMakeLists.txt
sed -i.bak "/^  bz2\$/d" CMakeLists.txt
sed -i.bak "s| -march=native | |g" contrib/WFA2-lib/CMakeLists.txt
sed -i.bak "s#defined(__APPLE__) || defined(__FreeBSD__)#defined(__APPLE__) || defined(__FreeBSD__) || defined(__EMSCRIPTEN__)#" contrib/fastahack/LargeFileSupport.h

mkdir -p build && cd build

emcmake cmake -DZIG=OFF -DOPENMP=OFF -DBUILD_DOC=OFF -DWFA_GITMODULE=ON -DCMAKE_EXE_LINKER_FLAGS="$EM_FLAGS -sINITIAL_MEMORY=64MB -sSTACK_SIZE=33554432" ..

emmake make -j4