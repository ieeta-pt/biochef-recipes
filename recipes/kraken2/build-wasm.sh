set -eo pipefail

cd src

sed -i.bak 's|-lz -pthread|-lz|g' Makefile

# A lookup line without a tab makes lookup_accession_numbers read past the end
# of its fields and crash; skip such lines instead.
sed -i.bak 's|^    auto fields = SplitString(line, "\\t", 2);$|&\n    if (fields.size() < 2) continue;|' lookup_accession_numbers.cc
grep -q '^    if (fields.size() < 2) continue;$' lookup_accession_numbers.cc

# The .k2d files are written as raw structs. Their size_t fields are 8 bytes
# natively and 4 in wasm32, so fix them at 64 bits to read native databases.
sed -i.bak -E 's/^(  )size_t (capacity_|size_|key_bits_|value_bits_);$/\1uint64_t \2;/' compact_hash.h
sed -i.bak -E 's/^(  )size_t (k|l);$/\1uint64_t \2;/' kraken2_data.h
sed -i.bak -E 's/^(  )size_t (node_count_|name_data_len_|rank_data_len_);$/\1uint64_t \2;/' taxonomy.h
test "$(grep -cE '^  uint64_t (capacity_|size_|key_bits_|value_bits_);$' compact_hash.h)" = 4
test "$(grep -cE '^  uint64_t (k|l);$' kraken2_data.h)" = 2
test "$(grep -cE '^  uint64_t (node_count_|name_data_len_|rank_data_len_);$' taxonomy.h)" = 3

emmake make CXX=em++ KRAKEN2_SKIP_FOPENMP="" CXXFLAGS="-Wall -std=c++11 -O2 -fPIC -DLINEAR_PROBING -sUSE_ZLIB=1 -Wno-narrowing -Wno-c++11-narrowing" LDFLAGS="$EM_FLAGS -sSTACK_SIZE=8MB" -j4 estimate_capacity build_db classify dump_table lookup_accession_numbers k2mask

for b in classify build_db estimate_capacity dump_table lookup_accession_numbers k2mask; do mv "$b" "$b.js"; done
