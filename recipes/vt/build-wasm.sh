git submodule update --init --recursive

python3 - <<'BIOCHEF_PY' || exit 1
import sys


def edit(path, pairs, start=None, end=None):
    src = open(path).read()
    a = src.index(start) if start else 0
    b = src.index(end, a) if end else len(src)
    part = src[a:b]
    for old, new, count in pairs:
        if part.count(old) != count:
            sys.exit(f"patch: expected {count} of {old!r} in {path}, found {part.count(old)}")
        part = part.replace(old, new)
    open(path, "w").write(src[:a] + part + src[b:])


# peek and validate wrote their reports to stderr, so the output was empty.
edit("peek.cpp", [("fprintf(stderr,", "fprintf(stdout,", 53), ("std::cerr <<", "std::cout <<", 6)],
     "    void print_stats()\n", "    void print_pdf()\n")
edit("validate.cpp", [("if (print) fprintf(stderr,", "if (print) fprintf(stdout,", 3)],
     "    void validate()\n", "    void print_options()\n")
edit("validate.cpp", [("std::clog", "std::cout", 9)],
     "    void print_stats()\n", "    ~Igor() {};\n")

# index wrote the index next to its input, under a name the caller cannot
# choose, took an uncompressed VCF and then failed without a word, and stopped
# silently on a file it could not open or index. It now takes -o, refuses a
# file that is not BGZF-compressed VCF or BCF, and says why it stops.
edit("index.cpp", [
    ("    kstring_t output_vcf_index_file;\n",
     "    kstring_t output_vcf_index_file;\n    std::string output_index_file;\n", 1),
    ('            TCLAP::SwitchArg arg_print("p", "p", "print options and summary []", cmd, false);\n',
     '            TCLAP::SwitchArg arg_print("p", "p", "print options and summary []", cmd, false);\n'
     '            TCLAP::ValueArg<std::string> arg_output_index_file("o", "o", "output index file [<in.vcf>.tbi or <in.bcf>.csi]", false, "", "str", cmd);\n', 1),
    ("            print = arg_print.getValue();\n",
     "            print = arg_print.getValue();\n            output_index_file = arg_output_index_file.getValue();\n", 1),
    ("        if (file==NULL)\n        {\n            exit(1);\n        }",
     "        if (file==NULL)\n        {\n"
     "            fprintf(stderr, \"[%s:%d %s] Cannot open %s\\n\", __FILE__, __LINE__, __FUNCTION__, input_vcf_file.c_str());\n"
     "            exit(1);\n        }", 1),
    ("        if (ftype.compression!=bgzf&&ftype.format!=vcf&&ftype.format!=bcf)\n        {\n",
     "        hts_close(file);\n"
     "        if (ftype.compression!=bgzf || (ftype.format!=vcf && ftype.format!=bcf))\n        {\n", 1),
    ("        int32_t ret;\n", "        int32_t ret = -1;\n", 1),
    ("            kputs(input_vcf_file.c_str(), &output_vcf_index_file);\n            kputs(\".csi\", &output_vcf_index_file);\n",
     "            kputs(output_index_file.empty() ? (input_vcf_file + \".csi\").c_str() : output_index_file.c_str(), &output_vcf_index_file);\n", 1),
    ("            ret = bcf_index_build(input_vcf_file.c_str(), min_shift);\n",
     "            ret = bcf_index_build2(input_vcf_file.c_str(), output_vcf_index_file.s, min_shift);\n", 1),
    ("            kputs(input_vcf_file.c_str(), &output_vcf_index_file);\n            kputs(\".tbi\", &output_vcf_index_file);\n",
     "            kputs(output_index_file.empty() ? (input_vcf_file + \".tbi\").c_str() : output_index_file.c_str(), &output_vcf_index_file);\n", 1),
    ("            ret = tbx_index_build(input_vcf_file.c_str(), min_shift, &conf);\n",
     "            ret = tbx_index_build2(input_vcf_file.c_str(), output_vcf_index_file.s, min_shift, &conf);\n", 1),
    ("        if (ret)\n        {\n            exit(1);\n        }",
     "        if (ret)\n        {\n"
     "            fprintf(stderr, \"[%s:%d %s] Cannot index %s: %s\\n\", __FILE__, __LINE__, __FUNCTION__, input_vcf_file.c_str(),\n"
     "                    ret==-2 ? \"it is not BGZF-compressed\" : \"it is malformed or unsorted\");\n"
     "            exit(1);\n        }", 1),
])
BIOCHEF_PY

sed -i.bak "s/-lbz2 -llzma -lcurl -lcrypto/\$(EXTRA_LIBS)/" Makefile
sed -i.bak "s/^CXX = g++/CXX ?= g++\nEXTRA_LIBS ?= -lbz2 -llzma -lcurl -lcrypto/" Makefile
sed -i.bak "s/^AR     = ar$/CC     ?= gcc\nAR     ?= ar/" lib/pcre2/Makefile
sed -i.bak "s/^\tgcc /\t\$(CC) /" lib/pcre2/Makefile
sed -i.bak "s/^\tar -rc/\t\$(AR) -rc/" lib/pcre2/Makefile
sed -i.bak "s/^\t-ranlib/\t-\$(RANLIB)/" lib/pcre2/Makefile

cd lib/htslib && autoreconf -i && emconfigure ./configure --disable-bz2 --disable-lzma --disable-libcurl --disable-plugins CFLAGS="-sUSE_ZLIB=1 -O3" LDFLAGS="-sUSE_ZLIB=1" && emmake make -j4 libhts.a && cd ../..

cd lib/Rmath && emmake make CC=emcc USEGCC=0 USECLANG=0 AR=emar -j4 libRmath.a && cd ../..

cd lib/pcre2 && emmake make CC=emcc AR=emar RANLIB=emranlib -j4 libpcre2.a && cd ../..

cd lib/libsvm && emmake make CXX=em++ AR=emar libsvm.a && cd ../..

mkdir -p lib/libdeflate && emar -rc lib/libdeflate/libdeflate.a
touch lib/htslib/libhts.a lib/Rmath/libRmath.a lib/pcre2/libpcre2.a lib/libsvm/libsvm.a lib/libdeflate/libdeflate.a

emmake make \
  CXX=em++ \
  AR=emar \
  OPTFLAG="-O3 -fexceptions" \
  EXTRA_LIBS="-sSTACK_SIZE=33554432 -sINITIAL_MEMORY=64MB $EM_FLAGS" \
  -j4 vt

mkdir -p build_wasm && mv vt build_wasm/vt.js && mv vt.wasm build_wasm/
