cd test

emcc -O2 -Wall -Wc++-compat -I.. -sUSE_ZLIB=1 bedcov-cr.c ../cgranges.c $EM_FLAGS -sSTACK_SIZE=8MB -o bedcov-cr

mv bedcov-cr bedcov-cr.js
