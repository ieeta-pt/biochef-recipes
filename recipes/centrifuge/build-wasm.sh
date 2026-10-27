set -eo pipefail

# centrifuge reports errors by throwing, and catches them to exit with a
# message and a status; centrifuge-build catches running out of memory to
# try again with less. Both need C++ exceptions, which emscripten leaves off.
for tool in class build inspect; do
  case $tool in
    class) bin=centrifuge-class ;;
    *) bin=centrifuge-$tool-bin ;;
  esac
  emmake make "$bin" \
    CXX=em++ \
    CC=emcc \
    RELEASE_FLAGS="-O2 -msimd128 -msse4.2 -std=c++11" \
    EXTRA_FLAGS="-std=c++11 -fwasm-exceptions $EM_FLAGS -sSTACK_SIZE=8MB -Dmain=centrifuge_tool_main -DBC_${tool^^} biochef_main.cpp" \
    NO_TBB=1
  mv "$bin" "$bin.js"
done
