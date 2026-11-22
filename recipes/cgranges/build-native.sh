set -eo pipefail

cd test

gcc -O2 -Wall -Wc++-compat -I.. bedcov-cr.c ../cgranges.c -o bedcov-cr -lz
