set -eo pipefail

# kroundup64 ORs in x >> 32, which is undefined for the 32-bit size_t of
# wasm32. x >> 16 >> 16 is 0 for a 32-bit x and x >> 32 for a 64-bit one.
python3 - <<'BIOCHEF_PY'
import sys

path = "kseq.h"
src = open(path).read()
old = "(x)|=(x)>>16, (x)|=(x)>>32, ++(x))"
if src.count(old) != 1:
    sys.exit(f"patch: expected one kroundup64 in {path}, found {src.count(old)}")
open(path, "w").write(src.replace(old, "(x)|=(x)>>16, (x)|=(x)>>16>>16, ++(x))"))
BIOCHEF_PY

# seqtk prints int64_t, uint64_t and size_t with %ld and %d, -Wno-format
# hiding it. That works where long is 64 bits, but in wasm32 long is 32 bits
# and the variadic arguments are read wrong: comp printed every length as 0.
# Each specifier takes the replacement the compiler proposes for the type of
# its argument, and the build then requires no format warning at all.
emcc -sUSE_ZLIB=1 -fsyntax-only -Wformat -fdiagnostics-parseable-fixits seqtk.c 2> format.log || true
python3 - <<'BIOCHEF_PY'
import re
import sys

fixit = re.compile(r'^fix-it:"seqtk\.c":\{(\d+):(\d+)-(\d+):(\d+)\}:"(%[a-z]+)"$')
fixes = []
for line in open("format.log"):
    m = fixit.match(line.strip())
    if m:
        r1, c1, r2, c2 = map(int, m.groups()[:4])
        if r1 != r2:
            sys.exit(f"patch: fix-it across lines at seqtk.c:{r1}")
        fixes.append((r1, c1, c2, m.group(5)))
if not fixes:
    sys.exit("patch: no format fix-its for seqtk.c")
lines = open("seqtk.c").read().split("\n")
for row, c1, c2, rep in sorted(fixes, reverse=True):
    text = lines[row - 1]
    if not re.fullmatch(r"%l?d", text[c1 - 1:c2 - 1]):
        sys.exit(f"patch: fix-it at seqtk.c:{row}:{c1} does not replace %d or %ld")
    lines[row - 1] = text[:c1 - 1] + rep + text[c2 - 1:]
open("seqtk.c", "w").write("\n".join(lines))
BIOCHEF_PY
emcc -sUSE_ZLIB=1 -fsyntax-only -Werror=format seqtk.c

mkdir -p out
emcc -O2 -Wall -Wno-unused-function -Wno-format -sUSE_ZLIB=1 $EM_FLAGS seqtk.c -lz -lm -o out/seqtk.js
