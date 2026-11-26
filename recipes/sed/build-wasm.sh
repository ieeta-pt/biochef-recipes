set -eo pipefail

# The release tarball of this tag adds what bootstrap generates (configure,
# Makefile.in, the gnulib files) to the files of the commit. It is checked by
# hash, and every file it shares with the commit must be identical.
curl -fsSL -o sed-4.10.tar.xz https://ftp.gnu.org/gnu/sed/sed-4.10.tar.xz
echo "b8e72182b2ec96a3574e2998c47b7aaa64cc20ce000d8e9ac313cc07cecf28c7  sed-4.10.tar.xz" | sha256sum -c -
tar -xJf sed-4.10.tar.xz
git ls-files -z | while IFS= read -r -d '' f; do
  if [ -f "sed-4.10/$f" ]; then
    cmp -s "$f" "sed-4.10/$f" || { echo "release tarball differs from the commit: $f" >&2; exit 1; }
  fi
done
cd sed-4.10

# Both checks run a test program that never returns under node.
FORCE_UNSAFE_CONFIGURE=1 emconfigure ./configure --disable-nls --host=wasm32-unknown-emscripten \
  gl_cv_func_nanosleep=no gl_cv_func_sleep_works=no

# Emscripten sets LANG from the browser's language. Fixing the locale keeps
# the output independent of it: UTF-8 characters, byte order collation.
echo "Module.preRun = [].concat(Module.preRun || [], () => { ENV.LANG = 'C'; ENV.LC_CTYPE = 'C.UTF-8'; });" > locale.js

BUILT=$(printf 'print:\n\t@echo $(BUILT_SOURCES)\n' | make -s -f Makefile -f - print)
emmake make -j4 EXEEXT=.js CFLAGS="-O2" LDFLAGS="$EM_FLAGS --pre-js locale.js" $BUILT sed/sed.js
mkdir -p ../out
cp sed/sed.js sed/sed.wasm ../out/
