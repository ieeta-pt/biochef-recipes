set -eo pipefail

# Strip the OpenMP include (no OMP in WASM); the bare `#pragma omp parallel for`
# lines remain as ignored comments when -fopenmp is not passed.
sed -i.bak 's|#include <omp.h>||' src/genomes.cpp
# long is 32 bits in wasm32. UniqueKMER packs k-mers of up to 32 bases (64
# bits) into its uint64 typedef and builds 64-bit edit-distance masks from 1L,
# so give both their real width.
sed -i.bak 's|^typedef long int64;|typedef int64_t int64;|; s|^typedef unsigned long uint64;|typedef uint64_t uint64;|' src/common.h
sed -i.bak 's|\b1L\b|1LL|g' src/editdistance.cpp src/genomes.cpp
grep -q '^typedef uint64_t uint64;' src/common.h
! grep -q '\b1L\b' src/editdistance.cpp src/genomes.cpp
# FastaReader refuses any name but *.fa, *.fasta or *.fna, and BioChef passes
# inputs as *.txt, so read every uncompressed name as plain FASTA.
sed -i.bak 's/else if(ends_with(mFilename, ".fasta") || ends_with(mFilename, ".fa") || ends_with(mFilename, ".fna")){/else if(!ends_with(mFilename, ".gz")){/' src/fastareader.cpp
grep -q 'else if(!ends_with(mFilename, ".gz")){' src/fastareader.cpp
# Drop -lz -lpthread -lomp and wire emcc runtime flags via LIBS.
sed -i.bak2 "s|^LIBS := -lz -lpthread.*$|LIBS := $EM_FLAGS -sSTACK_SIZE=8MB|" Makefile
emmake make CXX=em++ CXXFLAGS="-std=c++11 -O2 -I./inc -include stdint.h -sUSE_ZLIB=1 -Wno-c++11-narrowing -Wno-narrowing -Wno-format -Wno-source-uses-openmp" -j4
mkdir -p out && mv uniquekmer out/uniquekmer.js && mv uniquekmer.wasm out/uniquekmer.wasm
