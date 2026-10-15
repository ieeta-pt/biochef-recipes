sudo apt install libncurses-dev \
        zlib1g-dev \
        liblzma-dev \
        libbz2-dev \
        libdeflate-dev \
        libcurl4-openssl-dev \
        musl-tools

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
