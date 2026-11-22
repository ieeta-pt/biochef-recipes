set -eo pipefail

# The tn93 target of upstream's CMakeLists.txt, compiled directly: its sources,
# its compile options and the version from VERSION.txt. No OpenMP, as in wasm.
mkdir -p out
g++ -O3 -std=c++14 -funroll-loops \
    -DVERSION_NUMBER="\"$(head -n 1 VERSION.txt)\"" -Isrc \
    src/TN93.cpp src/stringBuffer.cc src/tn93_shared.cc src/argparse.cpp \
    -o out/tn93
