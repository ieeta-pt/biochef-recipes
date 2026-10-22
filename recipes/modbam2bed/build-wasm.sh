set -eo pipefail

# htslib at the commit modbam2bed pins as a submodule, with zlib only.
git submodule update --init --recursive htslib
cat > htslib/config.h <<'EOF_CONFIG'
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 600
#endif
#define HAVE_DRAND48 1
EOF_CONFIG
emmake make -C htslib -j4 CC=emcc AR=emar RANLIB=emranlib CFLAGS="-O2 -sUSE_ZLIB=1" \
  LIBS="-lz -lm" NONCONFIGURE_OBJS= lib-static

# argp, which the emscripten libc does not have, from argp-standalone,
# checked by commit and built without its autotools.
git clone https://github.com/ericonr/argp-standalone argp
git -C argp checkout --detach e5fe9ad9e83e6765cf8fa787f903d4c6792338b5
cat > argp/config.h <<'EOF_CONFIG'
#define HAVE_ALLOCA_H 1
#define HAVE_LIMITS_H 1
#define HAVE_MALLOC_H 1
#define HAVE_UNISTD_H 1
#define HAVE_STRERROR 1
#define HAVE_STRDUP 1
#define HAVE_ASPRINTF 1
#define HAVE_FLOCKFILE 1
#define HAVE_FUNLOCKFILE 1
#define HAVE_FPUTS_UNLOCKED 1
#define HAVE_FWRITE_UNLOCKED 1
#define HAVE_DECL_PROGRAM_INVOCATION_NAME 1
#define HAVE_DECL_PROGRAM_INVOCATION_SHORT_NAME 1
#define HAVE_DECL_CLEARERR_UNLOCKED 1
#define HAVE_DECL_FEOF_UNLOCKED 1
#define HAVE_DECL_FERROR_UNLOCKED 1
#define HAVE_DECL_FFLUSH_UNLOCKED 1
#define HAVE_DECL_FGETS_UNLOCKED 1
#define HAVE_DECL_FPUTC_UNLOCKED 1
#define HAVE_DECL_FPUTS_UNLOCKED 1
#define HAVE_DECL_FREAD_UNLOCKED 1
#define HAVE_DECL_FWRITE_UNLOCKED 1
#define HAVE_DECL_GETC_UNLOCKED 1
#define HAVE_DECL_GETCHAR_UNLOCKED 1
#define HAVE_DECL_PUTC_UNLOCKED 1
#define HAVE_DECL_PUTCHAR_UNLOCKED 1
EOF_CONFIG
for f in argp-ba argp-eexst argp-fmtstream argp-help argp-parse argp-pv argp-pvh; do
  emcc -O2 -D_GNU_SOURCE -DHAVE_CONFIG_H -Iargp -c argp/$f.c -o argp/$f.o
done
emar rcs argp/libargp.a argp/*.o

# A position with no reads on one strand gets that strand's score from
# nanf("") cast to size_t, which is undefined. gcc and earlier emscripten wrote 0; clang now
# drops the depth check and divides by zero. It is now 0 explicitly.
python3 - <<'BIOCHEF_PY'
import sys

path = "src/counts.c"
src = open(path).read()
old = '    size_t score = depth == 0 ? nanf("") : (1000 * tot) / depth;\n'
if src.count(old) != 1:
    sys.exit(f"patch: expected one score line in {path}, found {src.count(old)}")
src = src.replace(old, '    size_t score = depth == 0 ? 0 : (1000 * tot) / depth;\n')
open(path, "w").write(src)
BIOCHEF_PY

# NOTHREADS runs on one thread, since the build has no pthreads; WASM skips
# a check of the open file limit. Upstream's NOTHREADS path does not
# compile (it reads the BAM files from an undeclared `j`), and it would
# take a whole chromosome in one pileup, beyond wasm memory for most human
# chromosomes. It now runs the threaded path's worker on the same 1 Mb
# windows, in order.
python3 - <<'BIOCHEF_PY'
import sys

path = "src/modbam2bed.c"
src = open(path).read()
start = src.find("#ifdef NOTHREADS\nvoid process_region(")
end = src.find("#else\nvoid process_region(", start)
if start < 0 or end < 0 or src.count("#ifdef NOTHREADS\nvoid process_region(") != 1:
    sys.exit(f"patch: NOTHREADS process_region not found as expected in {path}")
src = src[:start] + """#ifdef NOTHREADS
void process_region(arguments_t args, const char *chr, int start, int end, char *ref, output_files bed_files) {
    fprintf(stderr, "Processing: %s:%d-%d\\n", chr, start, end);
    const int width = 1000000;
    init_output_buffers(bed_files);
    for (int rstart = start; rstart < end; rstart += width) {
        twarg *tw_args = xalloc(1, sizeof(*tw_args), "thread worker args");  // freed in worker
        tw_args->args = args;
        tw_args->chr = chr; tw_args->start = rstart; tw_args->end = min(rstart + width, end);
        plp_data res = (plp_data)pileup_worker(tw_args);
        if (res != NULL) {
            if (args.pileup) {
                print_pileup_data(res);
            } else {
                print_bedmethyl(
                    res, ref, 0,
                    args.extended, args.mod_base.abbrev, args.mod_base.base, bed_files);
            }
            destroy_plp_data(res);
        }
    }
    flush_output_buffers(bed_files, chr, args.extended, args.mod_base.abbrev);
}
""" + src[end:]
open(path, "w").write(src)
BIOCHEF_PY

for f in modbam2bed common counts bamiter args; do
  emcc -O2 -std=c99 -DNOTHREADS -DWASM -sUSE_ZLIB=1 -Isrc -Ihtslib -Iargp -c src/$f.c -o $f.o
done
emcc -O2 -sUSE_ZLIB=1 $EM_FLAGS modbam2bed.o common.o counts.o bamiter.o args.o \
  htslib/libhts.a argp/libargp.a -lz -lm -o modbam2bed.js

mkdir -p out
mv modbam2bed.js modbam2bed.wasm out/
