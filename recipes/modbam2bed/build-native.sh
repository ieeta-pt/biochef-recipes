set -eo pipefail

# htslib at the commit modbam2bed pins as a submodule, with zlib only, as
# in the wasm build. glibc has argp.
git submodule update --init --recursive htslib
cat > htslib/config.h <<'EOF_CONFIG'
#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 600
#endif
#define HAVE_DRAND48 1
EOF_CONFIG
make -C htslib -j4 LIBS="-lz -lm" NONCONFIGURE_OBJS= lib-static

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

for f in modbam2bed common counts bamiter args; do
  gcc -O2 -std=c99 -pthread -Isrc -Ihtslib -c src/$f.c -o $f.o
done
mkdir -p bin
gcc -O2 -pthread modbam2bed.o common.o counts.o bamiter.o args.o htslib/libhts.a -lz -lm -o bin/modbam2bed
