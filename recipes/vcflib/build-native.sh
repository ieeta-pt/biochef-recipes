sudo apt-get update
sudo apt-get install -y cmake pkg-config libbz2-dev liblzma-dev libcurl4-openssl-dev libdeflate-dev

git submodule update --init --recursive

sed -i.bak 's|"-march=native -D_FILE_OFFSET_BITS=64"|"-D_FILE_OFFSET_BITS=64"|' CMakeLists.txt
sed -i.bak "s| -march=native | |g" contrib/WFA2-lib/CMakeLists.txt
sed -i.bak 's|^set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ${ipo_supported})|set(CMAKE_INTERPROCEDURAL_OPTIMIZATION OFF)|' CMakeLists.txt
sed -i.bak "s|^  set(BUILD_SHARED_LIBS ON)$|  set(BUILD_SHARED_LIBS OFF)|" CMakeLists.txt
sed -i.bak "s|^if (NOT BUILD_STATIC) # only when not building static$|if (NOT BUILD_STATIC AND pybind11_FOUND) # only when not building static|" CMakeLists.txt
sed -i.bak "s|^  set(WFALIB wfa2) #|  set(WFALIB wfa2_static) #|" CMakeLists.txt

make -j4 CMAKE_FLAGS="-DZIG=OFF -DBUILD_DOC=OFF -DWFA_GITMODULE=ON -DCMAKE_EXE_LINKER_FLAGS=-Wl,--no-as-needed"
