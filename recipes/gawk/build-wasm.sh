set -eo pipefail

# The repository carries configure, Makefile.in and awkgram.c. bootstrap.sh
# touches them in order, so make does not try to regenerate them.
sh ./bootstrap.sh

# No dlopen in wasm, so no extensions.
emconfigure ./configure --disable-nls --disable-extensions --disable-mpfr CFLAGS="-O2"

# Emscripten sets LANG from the browser's language. Fixing the locale keeps
# the output independent of it: UTF-8 characters, byte order collation.
echo "Module.preRun = [].concat(Module.preRun || [], () => { ENV.LANG = 'C'; ENV.LC_CTYPE = 'C.UTF-8'; });" > locale.js

emmake make -j4 -C support
emmake make -j4 EXEEXT=.js CFLAGS="-O2" LIBS="$EM_FLAGS --pre-js locale.js" gawk.js
mkdir -p out
cp gawk.js gawk.wasm out/
