sudo apt-get update
sudo apt-get install -y cmake pkg-config libbz2-dev liblzma-dev libcurl4-openssl-dev libdeflate-dev

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

sed -i.bak 's|"-march=native -D_FILE_OFFSET_BITS=64"|"-D_FILE_OFFSET_BITS=64"|' CMakeLists.txt
sed -i.bak "s| -march=native | |g" contrib/WFA2-lib/CMakeLists.txt
sed -i.bak 's|^set(CMAKE_INTERPROCEDURAL_OPTIMIZATION ${ipo_supported})|set(CMAKE_INTERPROCEDURAL_OPTIMIZATION OFF)|' CMakeLists.txt
sed -i.bak "s|^  set(BUILD_SHARED_LIBS ON)$|  set(BUILD_SHARED_LIBS OFF)|" CMakeLists.txt
sed -i.bak "s|^if (NOT BUILD_STATIC) # only when not building static$|if (NOT BUILD_STATIC AND pybind11_FOUND) # only when not building static|" CMakeLists.txt
sed -i.bak "s|^  set(WFALIB wfa2) #|  set(WFALIB wfa2_static) #|" CMakeLists.txt

make -j4 CMAKE_FLAGS="-DZIG=OFF -DBUILD_DOC=OFF -DWFA_GITMODULE=ON -DCMAKE_EXE_LINKER_FLAGS=-Wl,--no-as-needed"
