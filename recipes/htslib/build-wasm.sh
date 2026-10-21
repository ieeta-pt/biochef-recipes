set -eo pipefail

git submodule update --init --recursive

python3 - <<'BIOCHEF_PY'
import sys

path = "tabix.c"
src = open(path).read()


def replace(old, new, count=1):
    global src
    if src.count(old) != count:
        sys.exit(f"patch: expected {count} of {old[:60]!r} in {path}, found {src.count(old)}")
    src = src.replace(old, new)


# tabix writes the index next to its input, named after it, and has no option
# to name it. Where the input's name is not the caller's to choose, the index
# cannot be found afterwards. --output-index names it; the build functions
# already take that name, and tabix passed NULL.
replace('    fprintf(fp, "   -m, --min-shift INT        set minimal interval size for CSI indices to 2^INT [14]\\n");\n',
        '    fprintf(fp, "   -m, --min-shift INT        set minimal interval size for CSI indices to 2^INT [14]\\n");\n'
        '    fprintf(fp, "       --output-index FILE    write the index to FILE instead of next to the input\\n");\n')
replace('    char *reheader = NULL;\n', '    char *reheader = NULL, *out_idx = NULL;\n')
replace('        {"threads", required_argument, NULL, \'@\'},\n',
        '        {"threads", required_argument, NULL, \'@\'},\n'
        '        {"output-index", required_argument, NULL, 6},\n')
replace("            case 'C': do_csi = 1; break;\n",
        "            case 'C': do_csi = 1; break;\n"
        "            case 6: out_idx = optarg; break;\n")
replace('    char *idx_fname = calloc(strlen(fname) + 6, 1);\n'
        '    if (!idx_fname) error("%s\\n", strerror(errno));\n'
        '    strcat(strcpy(idx_fname, fname), suffix);\n',
        '    char *idx_fname = out_idx ? strdup(out_idx) : calloc(strlen(fname) + 6, 1);\n'
        '    if (!idx_fname) error("%s\\n", strerror(errno));\n'
        '    if (!out_idx) strcat(strcpy(idx_fname, fname), suffix);\n')
replace('bam_index_build3(fname, min_shift, args.threads)', 'sam_index_build3(fname, out_idx, min_shift, args.threads)', 2)
replace('bcf_index_build3(fname, NULL, min_shift, args.threads)', 'bcf_index_build3(fname, out_idx, min_shift, args.threads)')
replace('tbx_index_build3(fname, NULL, min_shift, args.threads, &conf)', 'tbx_index_build3(fname, out_idx, min_shift, args.threads, &conf)', 2)

open(path, "w").write(src)
BIOCHEF_PY

# zlib only: no bzip2, lzma or libcurl.
cat > config.h <<'EOF_CONFIG'
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 600
#endif
#define HAVE_DRAND48 1
EOF_CONFIG
emmake make -j4 CC=emcc AR=emar RANLIB=emranlib CFLAGS="-O2 -sUSE_ZLIB=1" LDFLAGS="-sUSE_ZLIB=1" LIBS="-lz -lm" NONCONFIGURE_OBJS= lib-static bgzip.o tabix.o htsfile.o

# Linked apart: the Makefile writes LDFLAGS into config_vars.h with each
# quote as \x27, and in EM_FLAGS the letter after it, as in 'callMain',
# extends the hex escape, so hts.c would not compile.
mkdir -p out
for b in bgzip tabix htsfile; do
  emcc -O2 -sUSE_ZLIB=1 $EM_FLAGS "$b.o" libhts.a -lm -o "out/$b.js"
done
