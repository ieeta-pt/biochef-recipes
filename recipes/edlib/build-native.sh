set -eo pipefail

mkdir -p out
g++ -O2 -std=c++11 -Iedlib/include -o out/edlib-aligner edlib/src/edlib.cpp apps/aligner/aligner.cpp
