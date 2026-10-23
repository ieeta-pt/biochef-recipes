sudo apt-get update
sudo apt-get install -y cmake pkg-config libbz2-dev liblzma-dev libcurl4-openssl-dev libdeflate-dev

git submodule update --init --recursive

make -j4 CMAKE_FLAGS="-DZIG=OFF -DBUILD_DOC=OFF -DWFA_GITMODULE=ON -DCMAKE_EXE_LINKER_FLAGS=-Wl,--no-as-needed"
