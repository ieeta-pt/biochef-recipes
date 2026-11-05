set -eo pipefail

emmake make CC=emcc CFLAGS="-O2 -Wall -Wc++-compat -ffp-contract=off -sUSE_ZLIB=1" LIBS="-lm -sSTACK_SIZE=8MB $EM_FLAGS" -j4

mv miniasm miniasm.js && mv minidot minidot.js
