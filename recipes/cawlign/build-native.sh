set -eo pipefail

# cawlign looks for its files under a path fixed when it is built; the
# entry point gives it where they are when it runs.

# No OpenMP, whose threads write the sequences in another order in every
# run, and no -march=native, which builds for this machine only.
SOURCES="src/alignment.cpp src/stringBuffer.cc src/tn93_shared.cc src/argparse.cpp src/cawlign.cpp src/configparser.cpp src/scoring.cpp"
FLAGS="-O3 -std=c++14 -fsigned-char -funroll-loops -ffp-contract=off -Isrc -include src/biochef_library.h -DLIBRARY_PATH=biochef_library_path() -DVERSION_NUMBER=\"$(cat VERSION.txt)\""
mkdir -p out

# The hub ships a native operation as one file: cawlign's res directory goes
# into the program as a tar, written to a temporary directory each run.
tar --format=ustar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf biochef_res.tar res
printf '\t.section .rodata\n\t.global biochef_res_tar\n\t.global biochef_res_tar_end\n\t.balign 16\nbiochef_res_tar:\n\t.incbin "%s"\nbiochef_res_tar_end:\n\t.byte 0\n\t.section .note.GNU-stack,"",@progbits\n' "$PWD/biochef_res.tar" > biochef_res.S
gcc -c biochef_res.S -o biochef_res.o
g++ $FLAGS $SOURCES biochef_res.o -o out/cawlign
