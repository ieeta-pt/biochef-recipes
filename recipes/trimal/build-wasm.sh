cd source

emmake make CC=em++ FLAGS="-O2 -Wno-deprecated -Wno-implicit-function-declaration" -j4 all

em++ -O2 $EM_FLAGS -o trimal.js main.cpp \
    -lm alignment.o statisticsGaps.o utils.o \
    similarityMatrix.o statisticsConservation.o \
    sequencesMatrix.o compareFiles.o

em++ -O2 $EM_FLAGS -o readal.js readAl.cpp \
    -lm alignment.o statisticsGaps.o utils.o \
    similarityMatrix.o statisticsConservation.o \
    sequencesMatrix.o compareFiles.o

em++ -O2 $EM_FLAGS -o statal.js statAl.cpp \
    -lm alignment.o statisticsGaps.o utils.o \
    similarityMatrix.o statisticsConservation.o \
    sequencesMatrix.o compareFiles.o