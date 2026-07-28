sed -i.bak "s|^\\*/\$|*/\n#include <sys/time.h>\n#include <sys/resource.h>|" samblaster.cpp

emmake make CPP=em++ -j4

em++ -O3 $EM_FLAGS samblaster.o sbhash.o -o samblaster.js

mkdir -p out && mv samblaster.js samblaster.wasm out/