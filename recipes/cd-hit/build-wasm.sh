emmake make CC=em++ openmp=no zlib=no -j4

em++ -DNO_OPENMP -O2 $EM_FLAGS cdhit.o cdhit-common.o cdhit-utility.o -o cd-hit.js

em++ -DNO_OPENMP -O2 $EM_FLAGS cdhit-est.o cdhit-common.o cdhit-utility.o -o cd-hit-est.js

em++ -DNO_OPENMP -O2 $EM_FLAGS cdhit-2d.o cdhit-common.o cdhit-utility.o -o cd-hit-2d.js

em++ -DNO_OPENMP -O2 $EM_FLAGS cdhit-est-2d.o cdhit-common.o cdhit-utility.o -o cd-hit-est-2d.js

em++ -DNO_OPENMP -O2 $EM_FLAGS cdhit-div.o cdhit-common.o cdhit-utility.o -o cd-hit-div.js

em++ -DNO_OPENMP -O2 $EM_FLAGS cdhit-454.o cdhit-common.o cdhit-utility.o -o cd-hit-454.js

mkdir -p out && mv cd-hit.js cd-hit.wasm cd-hit-est.js cd-hit-est.wasm cd-hit-2d.js cd-hit-2d.wasm cd-hit-est-2d.js cd-hit-est-2d.wasm cd-hit-div.js cd-hit-div.wasm cd-hit-454.js cd-hit-454.wasm out/