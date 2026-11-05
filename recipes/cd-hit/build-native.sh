set -eo pipefail

make openmp=no CXXFLAGS=-ffp-contract=off cdhit-common.o cdhit-utility.o cdhit.o cdhit-est.o cdhit-2d.o cdhit-est-2d.o cdhit-div.o cdhit-454.o
FLAGS="-O2 -ffp-contract=off -DNO_OPENMP -DWITH_ZLIB"
g++ $FLAGS -c biochef_main.c++ -o biochef_main.o
g++ $FLAGS -DBIOCHEF_DIV -c biochef_main.c++ -o biochef_main_div.o
g++ $FLAGS -DBIOCHEF_454 -c biochef_main.c++ -o biochef_main_454.o
for p in cd-hit:cdhit:biochef_main cd-hit-est:cdhit-est:biochef_main cd-hit-2d:cdhit-2d:biochef_main \
         cd-hit-est-2d:cdhit-est-2d:biochef_main cd-hit-div:cdhit-div:biochef_main_div cd-hit-454:cdhit-454:biochef_main_454; do
  IFS=: read -r bin obj shim <<< "$p"
  g++ $FLAGS $shim.o $obj.o cdhit-common.o cdhit-utility.o -lz -o $bin
done
