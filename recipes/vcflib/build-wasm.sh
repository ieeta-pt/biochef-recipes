git submodule update --init --recursive

python3 - <<'BIOCHEF_PY'
import sys


def patch(path, old, new):
    src = open(path).read()
    if src.count(old) != 1:
        sys.exit(f"patch: expected one {old.strip()[:60]!r} in {path}, found {src.count(old)}")
    open(path, "w").write(src.replace(old, new))


# vcffilter evaluates its expression on a stack and pops operands without
# checking they are there, so an operator missing one, as in "QUAL >",
# read past the stack and crashed. Stop with an error instead.
patch(
    "src/Variant.cpp",
    "        else if (isOperator(token)) {\n",
    "        else if (isOperator(token)) {\n"
    "            if (results.size() < (token.type == RuleToken::NOT_OPERATOR ? 1u : 2u)) {\n"
    "                cerr << \"error: the operator \" << token.value << \" is missing an operand\" << endl;\n"
    "                exit(1);\n"
    "            }\n",
)

# vcfkeepsamples and vcfremovesamples take one sample per argument, and the
# recipe passes the list as one, so "s1,s2" was one name. A name the VCF
# does not have gave an empty column (keep) or was ignored (remove). Split
# each argument on commas and blanks, and refuse names the VCF does not have.
for path, var in (("src/vcfkeepsamples.cpp", "samplesToKeep"), ("src/vcfremovesamples.cpp", "samplesToRemove")):
    patch(path, '#include "Variant.h"\n', '#include "Variant.h"\n#include <algorithm>\n#include <sstream>\n')
    patch(
        path,
        f"        {var}.push_back(argv[i]);\n",
        "        string list = argv[i];\n"
        "        replace(list.begin(), list.end(), ',', ' ');\n"
        "        stringstream names(list);\n"
        "        string name;\n"
        f"        while (names >> name) {var}.push_back(name);\n",
    )
    patch(
        path,
        "    Variant var(variantFile);\n",
        f"    for (const string& name : {var}) {{\n"
        "        if (find(variantFile.sampleNames.begin(), variantFile.sampleNames.end(), name) == variantFile.sampleNames.end()) {\n"
        "            cerr << \"error: sample \" << name << \" is not in the VCF\" << endl;\n"
        "            return 1;\n"
        "        }\n"
        "    }\n"
        + ("    if (samplesToKeep.empty()) {\n"
           "        cerr << \"error: no sample to keep\" << endl;\n"
           "        return 1;\n"
           "    }\n" if var == "samplesToKeep" else "")
        + "    Variant var(variantFile);\n",
    )
BIOCHEF_PY

sed -i.bak "s|^find_package(BZip2 REQUIRED).*|if(NOT EMSCRIPTEN)\nfind_package(BZip2 REQUIRED)\nendif()|" CMakeLists.txt
sed -i.bak "s|^find_package(LibLZMA REQUIRED).*|if(NOT EMSCRIPTEN)\nfind_package(LibLZMA REQUIRED)\nendif()|" CMakeLists.txt
sed -i.bak "s|^find_package(ZLIB REQUIRED).*|if(NOT EMSCRIPTEN)\nfind_package(ZLIB REQUIRED)\nendif()|" CMakeLists.txt
sed -i.bak "s|^set_package_properties(ZLIB PROPERTIES TYPE REQUIRED)$|if(NOT EMSCRIPTEN)\nset_package_properties(ZLIB PROPERTIES TYPE REQUIRED)\nendif()|" CMakeLists.txt
sed -i.bak 's|"-march=native -D_FILE_OFFSET_BITS=64"|"-D_FILE_OFFSET_BITS=64"|' CMakeLists.txt
sed -i.bak "s|^if (NOT BUILD_STATIC) # only when not building static$|if (NOT BUILD_STATIC AND NOT EMSCRIPTEN AND pybind11_FOUND) # only when not building static|" CMakeLists.txt
sed -i.bak "s|set(flags \"-O2 -g -fPIC\")|set(flags \"-O2 -g -sUSE_ZLIB=1 -fPIC\")|" CMakeLists.txt
sed -i.bak "s|CONFIGURE_COMMAND ./configure --disable-s3|CONFIGURE_COMMAND emconfigure ./configure --disable-s3 --disable-bz2 --disable-lzma --disable-libcurl --disable-plugins CFLAGS=-sUSE_ZLIB=1 LDFLAGS=-sUSE_ZLIB=1|" CMakeLists.txt
sed -i.bak "s|BUILD_COMMAND \$(MAKE) CFLAGS=\${flags} lib-static|BUILD_COMMAND emmake \$(MAKE) CFLAGS=\${flags} lib-static|" CMakeLists.txt
sed -i.bak "s|set(vcflib_LIBS curl deflate)|set(vcflib_LIBS)|" CMakeLists.txt
sed -i.bak "/^  lzma\$/d" CMakeLists.txt
sed -i.bak "/^  bz2\$/d" CMakeLists.txt
sed -i.bak "s| -march=native | |g" contrib/WFA2-lib/CMakeLists.txt
sed -i.bak "s#defined(__APPLE__) || defined(__FreeBSD__)#defined(__APPLE__) || defined(__FreeBSD__) || defined(__EMSCRIPTEN__)#" contrib/fastahack/LargeFileSupport.h

mkdir -p build && cd build

emcmake cmake -DZIG=OFF -DOPENMP=OFF -DBUILD_DOC=OFF -DWFA_GITMODULE=ON -DCMAKE_EXE_LINKER_FLAGS="$EM_FLAGS -sINITIAL_MEMORY=64MB -sSTACK_SIZE=33554432" ..

emmake make -j4