set -eo pipefail

# Tentative definitions in headers. These were merged into one symbol under
# the old -fcommon default; modern clang gives each translation unit its own
# copy and the link fails with duplicate symbols. -fcommon is not an option
# here: wasm has no COMMON section and it crashes the backend, so the
# declarations are corrected instead. address_parser_status.h even documents
# the intent -- "we need to use an extern variable" -- and then omits extern.
sed -i 's|^const int SET_ADD_ERROR;|extern const int SET_ADD_ERROR;|; s|^int MEMBER;|extern int MEMBER;|' src/set.h
sed -i 's|^#include "set.h"|#include "set.h"\n\nconst int SET_ADD_ERROR = 0;\nint MEMBER;|' src/set.c
sed -i 's|^enum address_parser_status_type address_parser_status;|extern enum address_parser_status_type address_parser_status;|' src/address_parser_status.h
sed -i 's|^#include "address_parser_status.h"|#include "address_parser_status.h"\n\nenum address_parser_status_type address_parser_status;|' src/address_parser.y

# to_newick.h declares dump_newick as returning void; to_newick.c defines it
# returning int. Native builds tolerate the mismatch, but wasm type-checks
# calls and traps at run time, which silently breaks every tool that emits a
# tree. Correct the declaration to match the definition.
sed -i 's|^void dump_newick(struct rnode\* root);|int dump_newick(struct rnode* root);|' src/to_newick.h

# nw_prune is built by the generic loop, which compiles only prune.c, but
# prune.c calls read_line from readline.c. readline.c is attached explicitly
# to nw_display and nw_condense and to nothing else.
sed -i 's|^endforeach(app)|endforeach(app)\ntarget_sources(nw_prune PRIVATE readline.c)|' src/CMakeLists.txt

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
