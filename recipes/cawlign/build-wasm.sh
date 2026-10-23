set -eo pipefail

# cawlign looks for its files under a path fixed when it is built; the
# entry point gives it where they are when it runs.

# No OpenMP, whose threads write the sequences in another order in every
# run, and no -march=native, which builds for this machine only.
SOURCES="src/alignment.cpp src/stringBuffer.cc src/tn93_shared.cc src/argparse.cpp src/cawlign.cpp src/configparser.cpp src/scoring.cpp"
FLAGS="-O3 -std=c++14 -fsigned-char -funroll-loops -ffp-contract=off -Isrc -include src/biochef_library.h -DLIBRARY_PATH=biochef_library_path() -DVERSION_NUMBER=\"$(cat VERSION.txt)\""
mkdir -p out

em++ $FLAGS $SOURCES -o out/cawlign.js -sSTACK_SIZE=8MB --embed-file res@/biochef_res $EM_FLAGS
