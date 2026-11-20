set -eo pipefail

# The release tarball of this tag adds configure and the oniguruma submodule
# to the files of the commit. It is checked by hash, and every file it
# shares with the commit must be identical.
curl -fsSL -o jq-1.8.2.tar.gz https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-1.8.2.tar.gz
echo "71b8d6e8f5fe81f6c6d0d110e3892251f6ce76ed095abd315e26e6e1193af3af  jq-1.8.2.tar.gz" | sha256sum -c -
tar -xzf jq-1.8.2.tar.gz
git ls-files -z | while IFS= read -r -d '' f; do
  if [ -f "jq-1.8.2/$f" ]; then
    cmp -s "$f" "jq-1.8.2/$f" || { echo "release tarball differs from the commit: $f" >&2; exit 1; }
  fi
done
cd jq-1.8.2

# libjq and oniguruma are linked in statically, so the binary needs only
# libc and libm.
./configure --with-oniguruma=builtin --disable-docs --disable-shared --enable-static CFLAGS="-O2"

make -j4 -C vendor/oniguruma
BUILT=$(printf 'print:\n\t@echo $(BUILT_SOURCES)\n' | make -s -f Makefile -f - print)
make -j4 $BUILT jq
mkdir -p ../bin
cp jq ../bin/
