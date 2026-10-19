set -eo pipefail

python3 - <<'BIOCHEF_PY'
import sys

path = "src/genomes.cpp"
src = open(path).read()


def replace(old, new, count=1):
    global src
    if src.count(old) != count:
        sys.exit(f"patch: expected {count} of {old[:60]!r} in {path}, found {src.count(old)}")
    src = src.replace(old, new)


# The k-mer walks of the genomes and of the reference stopped one k-mer short
# (`pos < length - keylen`), so the last k-mer of each sequence was never
# seen, and a k-mer shared only there passed for unique. After a base other
# than A, C, G or T, `continue` moved one base further than the k-mer it had
# rebuilt, so every later k-mer of that sequence missed a base. A sequence
# whose k-mers all held such a base made `return` skip every later sequence.
# Walk each sequence once instead, restarting the k-mer after any other base.
walk = """        uint64 key = 0;
        uint32 run = 0;
        for(uint32 end = 0; end < seq.length(); end++) {
            switch(seq[end]) {
                case 'A': key = (key << 2) + 0; break;
                case 'T': key = (key << 2) + 1; break;
                case 'C': key = (key << 2) + 2; break;
                case 'G': key = (key << 2) + 3; break;
                default: key = 0; run = 0; continue;
            }
            if(++run < (uint32)keylen)
                continue;
            uint32 pos = end + 1 - keylen;
            (void)pos;
            key = (key << blankBits) >> blankBits;
"""

genome_start = "        // first calculate the first keylen-1 kmer\n"
genome_end = "            key = (key << blankBits) >> blankBits;\n            addKmer(key, i, reversed);\n"
a = src.index(genome_start)
b = src.index(genome_end, a)
src = src[:a] + walk + "            addKmer(key, i, reversed);\n" + src[b + len(genome_end):]

ref_start = "        string seq = allseq[c];\n        uint32 start = 0;\n"
ref_end = "            key = (key << blankBits) >> blankBits;\n\n            uint32 key32 = (uint32)key;\n"
a = src.index(ref_start)
b = src.index(ref_end, a)
src = src[:a] + "        string& seq = allseq[c];\n" + walk + "\n            uint32 key32 = (uint32)key;\n" + src[b + len(ref_end):]

# The output walk had the same bound, and for a genome shorter than k its
# unsigned subtraction wrapped, so substr threw past the end and the run
# aborted.
replace(
    "for(int pos=0; pos<genome.length() - mOptions->kmerKeyLen; pos++) {",
    "for(int pos=0; pos + mOptions->kmerKeyLen <= (int)genome.length(); pos++) {",
)

# A hit of a seed too near either end of a reference contig for the whole
# k-mer stopped the check of that seed's other hits, so k-mers that map
# elsewhere in the reference were kept.
replace(
    "if(compStart <0 || compStart + mOptions->kmerKeyLen > allseq[ctg].size())\n                                break;",
    "if(compStart <0 || compStart + mOptions->kmerKeyLen > allseq[ctg].size())\n                                continue;",
)

open(path, "w").write(src)
BIOCHEF_PY

# UniqueKMER refuses any input name but *.fa, *.fasta or *.fna, writes a
# report and a directory per genome next to its k-mers, and puts all the
# k-mers of a genome under one FASTA header. This entry point, appended to
# its main file, reads the input first, refuses what UniqueKMER would drop
# or misread, runs it in a temporary directory and writes the k-mers as
# FASTA, one record per k-mer.
sed -i 's/^int main(int argc, char\* argv\[\]){$/int biochef_upstream_main(int argc, char* argv[]){/' src/main.cpp
grep -q '^int biochef_upstream_main(int argc, char\* argv\[\]){$' src/main.cpp
cat >> src/main.cpp <<'BIOCHEF_EOF'

// BioChef entry point. UniqueKMER's own main runs as biochef_upstream_main.
//
// It reads the genomes (-f) and the reference (-r) first: FASTA, plain or
// gzip, told by content. It refuses, with the line at fault, what UniqueKMER
// would drop or misread without a word: text that is not FASTA, a record
// with no name or no bases, two records of the same ID (UniqueKMER keys the
// genomes by name, so the second replaced the first), and characters that are
// not nucleotides, such as gaps. UniqueKMER gets copies in upper case with U
// as T, in a temporary directory, where it also writes its report and the
// per-genome files.
//
// The k-mers are written to the file given with --bc-kmers, as FASTA with a
// record per k-mer: ">ID:position", the 1-based position of its first
// occurrence in the genome. UniqueKMER's own collection puts all the k-mers
// of a genome under one header, which FASTA readers take for one sequence.
#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <exception>
#include <fstream>
#include <new>
#include <set>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>
#include <zlib.h>

namespace biochef {

static std::string tmp_dir;

static void remove_tree(const std::string& path) {
    struct stat st;
    if (lstat(path.c_str(), &st) != 0) return;
    if (S_ISDIR(st.st_mode)) {
        DIR* d = opendir(path.c_str());
        if (d) {
            struct dirent* e;
            while ((e = readdir(d)) != NULL) {
                if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
                remove_tree(path + "/" + e->d_name);
            }
            closedir(d);
        }
        rmdir(path.c_str());
    } else {
        unlink(path.c_str());
    }
}

static void cleanup() {
    if (!tmp_dir.empty()) remove_tree(tmp_dir);
}

[[noreturn]] static void fail(const std::string& msg) {
    fprintf(stderr, "ERROR: %s\n", msg.c_str());
    exit(1);
}

struct Record {
    std::string header;  // the whole header line, as UniqueKMER names genomes
    std::string id;      // its first word
    std::string seq;
};

static bool is_nucleotide(char c) {
    return strchr("ACGTUNRYKMSWBDHV", c) != NULL;
}

// Reads a FASTA file, plain or gzip, strictly.
static std::vector<Record> read_fasta(const std::string& path, const char* what) {
    gzFile f = gzopen(path.c_str(), "rb");
    if (!f) fail(std::string("cannot open the ") + what + " " + path + ": " + strerror(errno));
    std::vector<Record> recs;
    std::set<std::string> ids;
    std::string line;
    std::vector<char> buf(1 << 16);
    long lineno = 0;
    bool pending = false;  // a partial line is in `line`
    for (;;) {
        char* r = gzgets(f, buf.data(), (int)buf.size());
        if (!r) {
            int err;
            const char* msg = gzerror(f, &err);
            if (err != Z_OK && err != Z_STREAM_END) fail(std::string("cannot read the ") + what + ": " + msg);
            if (!pending) break;
        } else {
            line += r;
            if (line.empty() || line.back() != '\n') { pending = true; continue; }
        }
        pending = false;
        ++lineno;
        while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) line.pop_back();
        if (!line.empty() && line[0] == '>') {
            if (!recs.empty() && recs.back().seq.empty())
                fail(std::string("record '") + recs.back().header + "' of the " + what + " has no bases (line " + std::to_string(lineno - 1) + ")");
            Record rec;
            rec.header = line.substr(1);
            size_t b = rec.header.find_first_not_of(" \t");
            if (b == std::string::npos)
                fail(std::string("a record of the ") + what + " has no name (line " + std::to_string(lineno) + ")");
            size_t e = rec.header.find_first_of(" \t", b);
            rec.id = rec.header.substr(b, e == std::string::npos ? std::string::npos : e - b);
            if (!ids.insert(rec.id).second)
                fail(std::string("two records of the ") + what + " are named '" + rec.id + "' (line " + std::to_string(lineno) + ")");
            recs.push_back(rec);
        } else {
            size_t end = line.find_last_not_of(" \t");
            std::string body = end == std::string::npos ? std::string() : line.substr(0, end + 1);
            if (!body.empty()) {
                if (recs.empty())
                    fail(std::string("the ") + what + " is not FASTA: line " + std::to_string(lineno) + " comes before any '>' header");
                for (size_t i = 0; i < body.size(); ++i) {
                    char c = body[i];
                    if (c >= 'a' && c <= 'z') c -= 'a' - 'A';
                    if (!is_nucleotide(c))
                        fail(std::string("the ") + what + " has '" + std::string(1, body[i]) + "', which is not a nucleotide, at line " + std::to_string(lineno) + "; gaps and amino acids are not taken");
                    recs.back().seq += c == 'U' ? 'T' : c;
                }
            }
        }
        line.clear();
        if (!r) break;
    }
    gzclose(f);
    if (recs.empty()) fail(std::string("the ") + what + " has no FASTA records");
    if (recs.back().seq.empty())
        fail(std::string("record '") + recs.back().header + "' of the " + what + " has no bases");
    return recs;
}

static void write_fasta(const std::string& path, const std::vector<Record>& recs) {
    std::ofstream out(path, std::ios::binary);
    for (const Record& r : recs) {
        out << '>' << r.header << '\n';
        for (size_t i = 0; i < r.seq.size(); i += 80) out << r.seq.substr(i, 80) << '\n';
    }
    if (!out) fail("cannot write " + path);
}

static long parse_int(const std::string& opt, const std::string& v, long lo, long hi) {
    errno = 0;
    char* end = NULL;
    long x = strtol(v.c_str(), &end, 10);
    if (v.empty() || *end || errno || x < lo || x > hi)
        fail(opt + " takes a whole number from " + std::to_string(lo) + " to " + std::to_string(hi) + ", not '" + v + "'");
    return x;
}

}  // namespace biochef

int main(int argc, char** argv) {
    using namespace biochef;
    std::string fasta, ref, kmers_out;
    long k = 25;
    std::vector<std::string> rest;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i], name = a, value;
        bool inline_value = false;
        if (a.compare(0, 2, "--") == 0 && a.find('=') != std::string::npos) {
            name = a.substr(0, a.find('='));
            value = a.substr(a.find('=') + 1);
            inline_value = true;
        }
        auto take = [&]() -> std::string {
            if (inline_value) return value;
            if (i + 1 >= argc) fail(name + " needs a value");
            return argv[++i];
        };
        if (name == "-f" || name == "--fasta") fasta = take();
        else if (name == "-r" || name == "--ref") ref = take();
        else if (name == "--bc-kmers") kmers_out = take();
        else if (name == "-o" || name == "--outdir") fail("-o is not taken: the k-mers go to the file given with --bc-kmers");
        else if (name == "-k" || name == "--kmer") { k = parse_int("-k", take(), 3, 32); rest.push_back("-k"); rest.push_back(std::to_string(k)); }
        else if (name == "-s" || name == "--spacing") { rest.push_back("-s"); rest.push_back(std::to_string(parse_int("-s", take(), 0, 100))); }
        else if (name == "-g" || name == "--genome_limit") { rest.push_back("-g"); rest.push_back(std::to_string(parse_int("-g", take(), 0, INT_MAX))); }
        else if (name == "-e" || name == "--edit_distance") { rest.push_back("-e"); rest.push_back(std::to_string(parse_int("-e", take(), 0, 16))); }
        else fail("unknown option " + a);
    }
    if (fasta.empty()) fail("the genomes (-f) are required");
    if (kmers_out.empty()) fail("the output file (--bc-kmers) is required");

    std::vector<Record> genomes = read_fasta(fasta, "genome file");
    std::vector<Record> reference;
    if (!ref.empty()) reference = read_fasta(ref, "reference file");

    const char* t = getenv("TMPDIR");
    std::string templ = std::string(t && *t ? t : "/tmp") + "/uniquekmer.XXXXXX";
    std::vector<char> tb(templ.begin(), templ.end());
    tb.push_back('\0');
    if (!mkdtemp(tb.data())) fail(std::string("cannot create a temporary directory: ") + strerror(errno));
    tmp_dir = tb.data();
    atexit(cleanup);

    write_fasta(tmp_dir + "/genomes.fasta", genomes);
    if (!ref.empty()) write_fasta(tmp_dir + "/reference.fasta", reference);
    reference.clear();
    reference.shrink_to_fit();

    std::vector<std::string> args = {argv[0], "-f", tmp_dir + "/genomes.fasta", "-o", tmp_dir + "/out"};
    if (!ref.empty()) { args.push_back("-r"); args.push_back(tmp_dir + "/reference.fasta"); }
    args.insert(args.end(), rest.begin(), rest.end());
    std::vector<char*> av;
    for (std::string& s : args) av.push_back(&s[0]);
    av.push_back(NULL);

    int rc;
    try {
        rc = biochef_upstream_main((int)args.size(), av.data());
    } catch (const std::bad_alloc&) {
        fail("UniqueKMER needs more memory than there is for these genomes");
    } catch (const std::length_error&) {
        fail("UniqueKMER needs more memory than there is for these genomes");
    } catch (const std::exception& e) {
        fail(std::string("UniqueKMER stopped: ") + e.what());
    }
    if (rc != 0) return rc;

    // UniqueKMER's collection: each genome's whole header, then its k-mers,
    // one per line, in the order of their first occurrence.
    std::ifstream in(tmp_dir + "/out/kmercollection.fasta", std::ios::binary);
    if (!in) fail("UniqueKMER wrote no k-mer collection");
    std::unordered_map<std::string, const Record*> by_header;
    for (const Record& g : genomes) by_header[g.header] = &g;
    std::vector<std::pair<const Record*, std::vector<std::string>>> found;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        if (line[0] == '>') {
            auto it = by_header.find(line.substr(1));
            if (it == by_header.end()) fail("UniqueKMER named a genome that is not in the input: " + line.substr(1));
            found.push_back({it->second, {}});
        } else {
            if (found.empty()) fail("UniqueKMER's k-mer collection does not start with a genome");
            found.back().second.push_back(line);
        }
    }
    std::ofstream out(kmers_out, std::ios::binary);
    if (!out) fail("cannot write " + kmers_out + ": " + strerror(errno));
    for (auto& g : found) {
        const std::string& seq = g.first->seq;
        std::unordered_map<std::string, size_t> first;
        for (const std::string& km : g.second) first.emplace(km, std::string::npos);
        for (size_t p = 0; p + k <= seq.size(); ++p) {
            auto f = first.find(seq.substr(p, k));
            if (f != first.end() && f->second == std::string::npos) f->second = p;
        }
        for (const std::string& km : g.second) {
            size_t p = first[km];
            if (p == std::string::npos) fail("UniqueKMER gave a k-mer that is not in genome " + g.first->id + ": " + km);
            out << '>' << g.first->id << ':' << (p + 1) << '\n' << km << '\n';
        }
    }
    out.close();
    if (!out) fail("cannot write " + kmers_out);
    return 0;
}
BIOCHEF_EOF

make -j4
mkdir -p out && mv uniquekmer out/uniquekmer
