
sed -i.bak "s|-lz -lpthread|${EM_FLAGS} -sSTACK_SIZE=8MB|" Makefile

emmake make CC=em++ CFLAGS="-std=c++11 -O2 -I./inc -sUSE_ZLIB=1 -Wno-c++11-narrowing -Wno-narrowing" -j4

mv mutscan mutscan.js
