set -eo pipefail
emmake make CC=emcc AR=emar CFLAGS="-O2 -sUSE_ZLIB=1" libgfa1.a main.o sys.o -j4
emcc -O2 $EM_FLAGS main.o sys.o libgfa1.a -o gfatools.js -lz
mkdir -p out && mv gfatools.js gfatools.wasm out/
