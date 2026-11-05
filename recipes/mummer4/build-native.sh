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

# Without OpenMP nucmer runs its query threads as std::thread, so the
# binary needs no libgomp.
./configure --disable-openmp --disable-shared CFLAGS="-O2" CXXFLAGS="-O2 -DNDEBUG"
make -j4 nucmer delta-filter show-coords show-snps
mkdir -p ../bin
cp nucmer delta-filter show-coords show-snps ../bin/
