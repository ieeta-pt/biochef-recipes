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
# The same mismatch in svg_graph_radial.h breaks radial SVG output (-r).
sed -i 's|^void display_svg_tree_radial($|int display_svg_tree_radial(|' src/svg_graph_radial.h
grep -q '^int display_svg_tree_radial($' src/svg_graph_radial.h

# condense allocates its group data with sizeof(grp_data), the size of the
# pointer. Native malloc rounds that up to enough room for the struct, but in
# wasm32 it is 4 of the 12 bytes the struct needs, and the rest overwrites the
# heap: condensed labels came out as "(null)".
sed -i 's|grp_data = malloc(sizeof(grp_data));|grp_data = malloc(sizeof(*grp_data));|' src/condense.c
grep -q 'malloc(sizeof(\*grp_data))' src/condense.c

# nw_prune is built by the generic loop, which compiles only prune.c, but
# prune.c calls read_line from readline.c. readline.c is attached explicitly
# to nw_display and nw_condense and to nothing else.
sed -i 's|^endforeach(app)|endforeach(app)\ntarget_sources(nw_prune PRIVATE readline.c)|' src/CMakeLists.txt

# nw_prune, nw_clade, nw_reroot and nw_distance take their labels, and nw_trim
# its depth, as arguments after the tree, where BioChef puts no parameter.
# This entry point moves the labels of a file given with --bc-labels (one per
# line), and a value given with --bc-last, after the other arguments.
cat > src/biochef_args.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int nw_main(int argc, char *argv[]);

static void fail(const char *what, const char *path)
{
	fprintf(stderr, "[newick-utils] %s %s\n", what, path);
	exit(EXIT_FAILURE);
}

static char **args;
static int nargs, size;

static void add(char *arg)
{
	if (nargs + 1 >= size) {
		size = size ? 2 * size : 64;
		args = realloc(args, size * sizeof *args);
		if (!args) fail("out of memory for", "the arguments");
	}
	args[nargs++] = arg;
}

/* Reads one label per line, ignoring empty lines and line ends (\n, \r\n). */
static int add_labels(const char *path, char ***labels, int n)
{
	FILE *fp = fopen(path, "r");
	char *line = NULL;
	size_t cap = 0;
	ssize_t len;
	if (!fp) fail("cannot read", path);
	while ((len = getline(&line, &cap, fp)) >= 0) {
		while (len && (line[len - 1] == '\n' || line[len - 1] == '\r')) line[--len] = 0;
		if (!len) continue;
		*labels = realloc(*labels, (n + 1) * sizeof **labels);
		if (!*labels || !((*labels)[n] = strdup(line))) fail("out of memory for", path);
		++n;
	}
	free(line);
	fclose(fp);
	return n;
}

int main(int argc, char *argv[])
{
	char **last = NULL;
	int i, nlast = 0;
	add(argv[0]);
	for (i = 1; i < argc; ++i) {
		if (!strcmp(argv[i], "--bc-labels") || !strcmp(argv[i], "--bc-last")) {
			if (i + 1 >= argc) fail("needs a value:", argv[i]);
			if (!strcmp(argv[i], "--bc-labels")) {
				int before = nlast;
				nlast = add_labels(argv[i + 1], &last, nlast);
				if (nlast == before) fail("no labels in", argv[i + 1]);
			} else {
				last = realloc(last, (nlast + 1) * sizeof *last);
				if (!last) fail("out of memory for", argv[i]);
				last[nlast++] = argv[i + 1];
			}
			++i;
		} else add(argv[i]);
	}
	for (i = 0; i < nlast; ++i) add(last[i]);
	args[nargs] = NULL;
	return nw_main(nargs, args);
}
EOF
cat >> src/CMakeLists.txt <<'EOF'
foreach(app prune clade reroot distance trim)
	target_sources(nw_${app} PRIVATE biochef_args.c)
endforeach(app)
set_source_files_properties(prune.c clade.c reroot.c distance.c trim.c PROPERTIES COMPILE_DEFINITIONS main=nw_main)
EOF

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
