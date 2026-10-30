set -eo pipefail

mkdir -p build && cd build

emcmake cmake .. \
  -DUSE_LIBXML=OFF -DUSE_LUA=OFF -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_EXE_LINKER_FLAGS="$EM_FLAGS"

# Build the tools explicitly rather than "all": the tests/ targets link
# tree_stubs.c alongside libnutils and hit the same duplicate-symbol problem,
# and none of them ships.
emmake make -j4 nw_display nw_reroot nw_prune nw_topology nw_labels \
  nw_distance nw_stats nw_order nw_indent nw_clade nw_condense nw_trim

cd ..
mkdir -p out && cp build/src/nw_*.js build/src/nw_*.wasm out/
