git submodule update --init --recursive

mkdir -p build && cd build

emcmake cmake -DZIG=OFF -DOPENMP=OFF -DBUILD_DOC=OFF -DWFA_GITMODULE=ON -DCMAKE_EXE_LINKER_FLAGS="$EM_FLAGS -sINITIAL_MEMORY=64MB -sSTACK_SIZE=33554432" ..

emmake make wfa2_static
emmake make wfa2
emmake make wfa2cpp_static
emmake make wfa2cpp
emmake make -j4
