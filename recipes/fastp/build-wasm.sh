set -eo pipefail

# fastp counts reads and bases, and sizes its duplication filter, in long,
# and takes its uint64 from unsigned long. long is 64 bits on 64-bit Linux
# and macOS but 32 bits in wasm32, where the filter size (2^32 bits) is 0
# and the run stops on a remainder by zero, and base counts past 2^31 would
# wrap. Every long in the code, outside strings and comments, is long long.
python3 - <<'BIOCHEF_PY'
import glob
import re

token = re.compile(r"(?<!long )\blong\b(?! long)")
literal = re.compile(r'"(?:\\.|[^"\\])*"|//.*$')
changed = 0
for path in sorted(glob.glob("src/*.cpp") + glob.glob("src/*.h")):
    lines = open(path).read().split("\n")
    out = []
    for line in lines:
        parts, last = [], 0
        for m in literal.finditer(line):
            parts.append(token.sub("long long", line[last:m.start()]))
            parts.append(m.group(0))
            last = m.end()
        parts.append(token.sub("long long", line[last:]))
        out.append("".join(parts))
    new = "\n".join(out)
    if new != "\n".join(lines):
        changed += 1
        open(path, "w").write(new)
if changed == 0:
    raise SystemExit("patch: no long found in src")
BIOCHEF_PY

# The build has no pthreads, and fastp runs a reader, workers and writers
# on threads that wait on each other. Here the one worker and the writers
# take every pack of 1000 reads as soon as the reader has it, so no thread
# waits on another and memory holds one pack at a time. The native build
# keeps the threads.
python3 - <<'BIOCHEF_PY'
import re
import sys

def replace_once(src, path, old, new):
    if src.count(old) != 1:
        sys.exit(f"patch: expected one {old.strip().splitlines()[0]!r} in {path}, found {src.count(old)}")
    return src.replace(old, new)

for cls, base, writers in [
    ("SingleEndProcessor", "src/seprocessor", ["mLeftWriter", "mFailedWriter"]),
    ("PairEndProcessor", "src/peprocessor", ["mLeftWriter", "mRightWriter", "mUnpairedLeftWriter",
        "mUnpairedRightWriter", "mMergedWriter", "mFailedWriter", "mOverlappedWriter"]),
]:
    path = base + ".h"
    src = open(path).read()
    src = replace_once(src, path, "    void producerTask();\n",
        "    void producerTask();\n#ifdef __EMSCRIPTEN__\n    void serialStep();\n    ThreadConfig* mSerialConfig;\n#endif\n")
    open(path, "w").write(src)

    path = base + ".cpp"
    src = open(path).read()
    producer = f"    std::thread producer(std::bind(&{cls}::producerTask, this));\n"
    src = replace_once(src, path, producer,
        f"#ifdef __EMSCRIPTEN__\n    mOptions->thread = 1;\n#else\n{producer}#endif\n")

    start = src.find("    std::thread** threads = new thread*[mOptions->thread];\n")
    end = src.find('    if(mOptions->verbose)\n        loginfo("start to generate reports\\n");\n', start)
    if start < 0 or end < 0:
        sys.exit(f"patch: thread section not found in {path}")
    threaded = src[start:end]
    thread_vars = re.findall(r"    std::thread\* (\w+WriterThread) = NULL;\n", threaded)
    if len(thread_vars) != len(writers):
        sys.exit(f"patch: expected {len(writers)} writer threads in {path}, found {len(thread_vars)}")
    serial = "    std::thread** threads = new thread*[mOptions->thread];\n    threads[0] = NULL;\n"
    serial += "".join(f"    std::thread* {v} = NULL;\n" for v in thread_vars)
    serial += "    mSerialConfig = configs[0];\n    producerTask();\n    consumerTask(configs[0]);\n"
    serial += "".join(f"    if({w})\n        writeTask({w});\n" for w in writers)
    src = src[:start] + f"#ifdef __EMSCRIPTEN__\n{serial}#else\n{threaded}#endif\n\n" + src[end:]

    src, n = re.subn(r"\n( +)producePack\(pack\);\n",
        r"\n\1producePack(pack);\n#ifdef __EMSCRIPTEN__\n\1serialStep();\n#endif\n", src)
    if n != 2:
        sys.exit(f"patch: expected two producePack calls in {path}, found {n}")

    src += f"\n#ifdef __EMSCRIPTEN__\nvoid {cls}::serialStep() {{\n"
    src += "    if(!mSerialConfig->canBeStopped())\n        consumePack(mSerialConfig);\n"
    src += "".join(f"    if({w})\n        {w}->output();\n" for w in writers)
    src += "}\n#endif\n"
    open(path, "w").write(src)
BIOCHEF_PY

# DYNAMIC_ZLIB takes zlib.h from the emscripten zlib port that is linked,
# not the copy of the headers in src/zlib.
mkdir -p out
em++ -O3 -std=c++11 -DDYNAMIC_ZLIB -sUSE_ZLIB=1 $EM_FLAGS \
  src/*.cpp -lz -o out/fastp.js
