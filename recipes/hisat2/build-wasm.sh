set -eo pipefail

# hisat2 reports errors by throwing, and catches them to exit with a
# message and a status; hisat2-build catches running out of memory to try
# again with less. Both need C++ exceptions, which emscripten leaves off.
for tool in align build inspect; do
  emmake make "hisat2-$tool-s" \
    CXX=em++ \
    CC=emcc \
    RELEASE_FLAGS="-O2 -msimd128 -msse4.2 -std=c++11" \
    EXTRA_FLAGS="-std=c++11 -fwasm-exceptions $EM_FLAGS -sSTACK_SIZE=8MB -Dmain=hisat2_tool_main -DBC_${tool^^} biochef_main.cpp" \
    NO_TBB=1
  mv "hisat2-$tool-s" "hisat2-$tool-s.js"
done
