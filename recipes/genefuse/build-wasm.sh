set -eo pipefail

FLAGS="-std=c++11 -O2 -ffp-contract=off -I./inc -include src/biochef_genefuse.h"

sed -i "s|-lz -lpthread|${EM_FLAGS} -sSTACK_SIZE=8MB|" Makefile
grep -q 'STACK_SIZE=8MB' Makefile
emmake make CC=em++ CFLAGS="$FLAGS -Wall -sUSE_ZLIB=1" -j4

mv genefuse genefuse.js
