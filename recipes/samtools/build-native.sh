git clone --branch 1.21 --recurse-submodules https://github.com/samtools/htslib.git htslib

cd htslib
autoheader
autoconf
./configure
make
cd ..

autoheader
autoconf -Wno-syntax
./configure --with-htslib="$PWD/htslib"
make
