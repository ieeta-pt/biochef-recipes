set -eo pipefail

# No step is fused into an FMA.
FLAGS="-O2 -ffp-contract=off"

gcc $FLAGS -std=c99 -Wall -c biochef_math.c -o biochef_math.o
make CXX=g++ CXXFLAGS="$FLAGS -Wall -include src/biochef_filtlong.h" LIB="$PWD/biochef_math.o -lz" -j4
cp bin/filtlong filtlong
