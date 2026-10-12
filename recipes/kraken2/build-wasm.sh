cd src

sed -i.bak 's|-lz -pthread|-lz|g' Makefile

emmake make CXX=em++ KRAKEN2_SKIP_FOPENMP="" CXXFLAGS="-Wall -std=c++11 -O2 -fPIC -DLINEAR_PROBING -sUSE_ZLIB=1 -Wno-narrowing -Wno-c++11-narrowing" LDFLAGS="$EM_FLAGS -sSTACK_SIZE=8MB " -j4 estimate_capacity build_db classify dump_table lookup_accession_numbers k2mask

for b in classify build_db estimate_capacity dump_table lookup_accession_numbers k2mask; do mv "$b" "$b.js"; done
