git submodule update --init --recursive

cd lib/htslib && autoreconf -i && emconfigure ./configure --disable-bz2 --disable-lzma --disable-libcurl --disable-plugins CFLAGS="-sUSE_ZLIB=1 -O3" LDFLAGS="-sUSE_ZLIB=1" && emmake make -j4 libhts.a && cd ../..

cd lib/Rmath && emmake make CC=emcc USEGCC=0 USECLANG=0 AR=emar -j4 libRmath.a && cd ../..

cd lib/pcre2 && emmake make CC=emcc AR=emar RANLIB=emranlib -j4 libpcre2.a && cd ../..

cd lib/libsvm && emmake make CXX=em++ AR=emar libsvm.a && cd ../..

mkdir -p lib/libdeflate && emar -rc lib/libdeflate/libdeflate.a
touch lib/htslib/libhts.a lib/Rmath/libRmath.a lib/pcre2/libpcre2.a lib/libsvm/libsvm.a lib/libdeflate/libdeflate.a

emmake make \
  CXX=em++ \
  AR=emar \
  OPTFLAG="-O3 -fexceptions" \
  EXTRA_LIBS="-sSTACK_SIZE=33554432 -sINITIAL_MEMORY=64MB $EM_FLAGS" \
  -j4 vt

mkdir -p build_wasm && mv vt build_wasm/vt.js && mv vt.wasm build_wasm/
