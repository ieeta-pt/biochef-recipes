set -eo pipefail

# The release tarball of this tag adds what yaggo and autotools generate
# (configure, Makefile.in, the *_cmdline.hpp parsers) to the files of the
# commit. It is checked by hash, and every file it shares with the commit
# must be identical.
curl -fsSL -o mummer-4.0.1.tar.gz https://github.com/mummer4/mummer/releases/download/v4.0.1/mummer-4.0.1.tar.gz
echo "bc20ae2701a0b2e323e4e515b7cfa18a0f0cb34a4ff5844b289b2de0154e3d3e  mummer-4.0.1.tar.gz" | sha256sum -c -
tar -xzf mummer-4.0.1.tar.gz
git ls-files -z | while IFS= read -r -d '' f; do
  if [ -f "mummer-4.0.1/$f" ]; then
    cmp -s "$f" "mummer-4.0.1/$f" || { echo "release tarball differs from the commit: $f" >&2; exit 1; }
  fi
done
cd mummer-4.0.1

# No pthreads in the build: nucmer runs its query worker once, on the main
# thread, where it starts one std::thread per query thread.
python3 - <<'BIOCHEF_PY'
import sys

path = "src/umd/nucmer_main.cc"
src = open(path).read()
old = """      std::vector<std::thread> threads;
      for(unsigned int i = 0; i < nb_threads; ++i)
        threads.push_back(std::thread(query_thread, aligner.get(), &parser, &output, &args));

      for(auto& th : threads)
        th.join();
"""
if src.count(old) != 1:
    sys.exit(f"patch: query threads not found as expected in {path}")
new = "#ifdef __EMSCRIPTEN__\n      query_thread(aligner.get(), &parser, &output, &args);\n#else\n" + old + "#endif\n"
open(path, "w").write(src.replace(old, new))
BIOCHEF_PY

emconfigure ./configure --disable-openmp --disable-shared --host=wasm32-unknown-emscripten \
  CFLAGS="-O2" CXXFLAGS="-O2 -DNDEBUG"
emmake make -j4 nucmer.js delta-filter.js show-coords.js show-snps.js EXEEXT=.js LDFLAGS="$EM_FLAGS"
mkdir -p ../out
cp nucmer.js nucmer.wasm delta-filter.js delta-filter.wasm show-coords.js show-coords.wasm show-snps.js show-snps.wasm ../out/
