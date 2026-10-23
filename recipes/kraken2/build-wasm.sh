set -eo pipefail

cd src

# kraken2 catches failures to allocate memory and to open its outputs as
# exceptions, which emscripten leaves off.
CXXFLAGS="-Wall -std=c++11 -O2 -fPIC -DLINEAR_PROBING -sUSE_ZLIB=1 -Wno-narrowing -Wno-c++11-narrowing -fwasm-exceptions"
emmake make CXX=em++ KRAKEN2_SKIP_FOPENMP="" CXXFLAGS="$CXXFLAGS" LDFLAGS="$EM_FLAGS -fwasm-exceptions -sSTACK_SIZE=8MB" \
  estimate_capacity lookup_accession_numbers k2mask
for tool in classify build_db dump_table; do
  define=$(case $tool in classify) echo BC_CLASSIFY ;; build_db) echo BC_BUILD ;; dump_table) echo BC_DUMP ;; esac)
  em++ $CXXFLAGS -D$define -c biochef_main.cpp -o "bc_$tool.o"
  emmake make CXX=em++ KRAKEN2_SKIP_FOPENMP="" CXXFLAGS="$CXXFLAGS -Dmain=kraken2_tool_main" \
    LDFLAGS="bc_$tool.o $EM_FLAGS -fwasm-exceptions -sSTACK_SIZE=8MB" "$tool"
done

for b in classify build_db estimate_capacity dump_table lookup_accession_numbers k2mask; do mv "$b" "$b.js"; done
