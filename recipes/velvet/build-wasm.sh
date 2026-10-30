set -eo pipefail

# k-mers up to 63; reads, and references, longer than 32 kb
DEF="-DMAXKMERLENGTH=63 -DCATEGORIES=2 -DLONGSEQUENCES"
MAKEVARS="MAXKMERLENGTH=63 LONGSEQUENCES=1"

for tool in velveth velvetg; do
  define=$(case $tool in velveth) echo BC_VELVETH ;; velvetg) echo BC_VELVETG ;; esac)
  emcc -Wall -O2 $DEF -D$define -c biochef_main.c -o "bc_$tool.o"
  emmake make "$tool" CC=emcc $MAKEVARS CFLAGS="-Wall -sUSE_ZLIB=1 -Dmain=velvet_tool_main" LDFLAGS="bc_$tool.o" \
    LIBS="-lm -sSTACK_SIZE=8MB $EM_FLAGS"
done

mkdir -p out
for tool in velveth velvetg; do mv "$tool" "out/$tool.js"; mv "$tool.wasm" "out/$tool.wasm"; done
