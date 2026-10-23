sudo apt-get update
sudo apt-get install -y libbz2-dev liblzma-dev libcurl4-openssl-dev libssl-dev

git submodule update --init --recursive

make -j4 vt
