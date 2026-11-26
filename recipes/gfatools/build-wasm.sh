set -eo pipefail

python3 - <<'BIOCHEF_PY'
import sys

path = "main.c"
src = open(path).read()


def replace(old, new, count=1):
    global src
    if src.count(old) != count:
        sys.exit(f"patch: expected {count} of {old[:60]!r} in {path}, found {src.count(old)}")
    src = src.replace(old, new)


# gfa2bed, blacklist and bubble work on the stable coordinates of an rGFA:
# the SN, SO and SR tags of each segment. On a graph without them they wrote
# nothing and exited with 0, so a plain GFA looked like a graph with no
# bubbles. They now stop and say which segment lacks them.
replace(
    "int main_gfa2bed(int argc, char *argv[])\n",
    """static int check_rgfa(const gfa_t *g, const char *cmd)
{
	uint32_t i;
	if (g->n_seg == 0) {
		fprintf(stderr, "ERROR: the graph has no segments\\n");
		return -1;
	}
	for (i = 0; i < g->n_seg; ++i) {
		const gfa_seg_t *s = &g->seg[i];
		if (s->snid < 0 || s->soff < 0 || s->rank < 0) {
			fprintf(stderr, "ERROR: segment '%s' lacks an SN, SO or SR tag; %s needs an rGFA, such as minigraph writes\\n", s->name, cmd);
			return -1;
		}
	}
	return 0;
}

int main_gfa2bed(int argc, char *argv[])
""",
)

read = "\tg = gfa_read(argv[o.ind]);\n\tif (g == 0) {\n\t\tfprintf(stderr, \"ERROR: failed to read the graph\\n\");\n\t\treturn 2;\n\t}\n"
for cmd in ("gfa2bed", "blacklist", "bubble"):
    a = src.index(f"int main_{cmd}(int argc, char *argv[])\n{{")
    b = src.index("\nint main_", a + 1)
    part = src[a:b]
    if part.count(read) != 1:
        sys.exit(f"patch: expected one graph read in main_{cmd}")
    part = part.replace(read, read + f"\tif (check_rgfa(g, \"{cmd}\") < 0) {{\n\t\tgfa_destroy(g);\n\t\treturn 1;\n\t}}\n")
    src = src[:a] + part + src[b:]

open(path, "w").write(src)
BIOCHEF_PY
emmake make CC=emcc AR=emar CFLAGS="-O2 -sUSE_ZLIB=1" libgfa1.a main.o sys.o -j4
emcc -O2 $EM_FLAGS main.o sys.o libgfa1.a -o gfatools.js -lz
mkdir -p out && mv gfatools.js gfatools.wasm out/
