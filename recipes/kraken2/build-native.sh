set -eo pipefail

cd src

CXXFLAGS="-fopenmp -Wall -std=c++11 -O3 -fPIC -DLINEAR_PROBING"
make -j4 CXXFLAGS="$CXXFLAGS" estimate_capacity lookup_accession_numbers k2mask
for tool in classify build_db dump_table; do
  define=$(case $tool in classify) echo BC_CLASSIFY ;; build_db) echo BC_BUILD ;; dump_table) echo BC_DUMP ;; esac)
  g++ $CXXFLAGS -D$define -c biochef_main.cpp -o "bc_$tool.o"
  make CXXFLAGS="$CXXFLAGS -Dmain=kraken2_tool_main" LDFLAGS="bc_$tool.o" "$tool"
done
