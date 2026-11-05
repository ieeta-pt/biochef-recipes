set -eo pipefail

emmake make CC=em++ openmp=no CXXFLAGS='-sUSE_ZLIB=1 -ffp-contract=off' cdhit-common.o cdhit-utility.o cdhit.o cdhit-est.o cdhit-2d.o cdhit-est-2d.o cdhit-div.o cdhit-454.o
FLAGS="-O2 -ffp-contract=off -DNO_OPENMP -DWITH_ZLIB -sUSE_ZLIB=1"
em++ $FLAGS -c biochef_main.c++ -o biochef_main.o
em++ $FLAGS -DBIOCHEF_DIV -c biochef_main.c++ -o biochef_main_div.o
em++ $FLAGS -DBIOCHEF_454 -c biochef_main.c++ -o biochef_main_454.o
for p in cd-hit:cdhit:biochef_main cd-hit-est:cdhit-est:biochef_main cd-hit-2d:cdhit-2d:biochef_main \
         cd-hit-est-2d:cdhit-est-2d:biochef_main cd-hit-div:cdhit-div:biochef_main_div cd-hit-454:cdhit-454:biochef_main_454; do
  IFS=: read -r bin obj shim <<< "$p"
  em++ $FLAGS $shim.o $obj.o cdhit-common.o cdhit-utility.o -o $bin.js $EM_FLAGS
done

mkdir -p out
for bin in cd-hit cd-hit-est cd-hit-2d cd-hit-est-2d cd-hit-div cd-hit-454; do mv $bin.js $bin.wasm out/; done
