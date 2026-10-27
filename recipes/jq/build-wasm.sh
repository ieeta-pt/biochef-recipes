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

emconfigure ./configure --host=wasm32-unknown-emscripten --with-oniguruma=builtin \
  --disable-docs --disable-shared --enable-static CFLAGS="-O2"

# Emscripten sets LANG from the browser's language. Fixing the locale keeps
# the output independent of it: UTF-8 characters, byte order collation.
echo "Module.preRun = [].concat(Module.preRun || [], () => { ENV.LANG = 'C'; ENV.LC_CTYPE = 'C.UTF-8'; });" > locale.js

emmake make -j4 -C vendor/oniguruma
BUILT=$(printf 'print:\n\t@echo $(BUILT_SOURCES)\n' | make -s -f Makefile -f - print)
emmake make -j4 EXEEXT=.js LDFLAGS="$EM_FLAGS --pre-js $PWD/locale.js" $BUILT jq.js
mkdir -p ../out
cp jq.js jq.wasm ../out/
