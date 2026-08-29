mkdir -p build && cd build

embuilder build zlib

emcmake cmake -Dspoa_use_simde=ON -Dspoa_optimize_for_native=OFF -Dspoa_build_executable=ON -Dspoa_build_tests=OFF -DCMAKE_EXE_LINKER_FLAGS="$EM_FLAGS" ..

emmake make -j4 spoa_exe