set -eo pipefail

cc -O2 -Wall -c biochef_main.c -o biochef_main.o
make CFLAGS="-g -Wall -Wno-unused-function -O3 -Dmain=bwa_main" LIBS="biochef_main.o -lm -lz -lpthread"
