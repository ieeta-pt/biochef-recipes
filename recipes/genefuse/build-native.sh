set -eo pipefail

# GeneFuse misreads, without a word, a reference with blank lines, genes on
# chromosomes the reference lacks or past their ends, and reads in files not
# named .fq or .fastq. This entry point, linked in front of GeneFuse's main,
# reads every input first and refuses those. The same entry point is in
# build-wasm.sh.
cat > src/biochef_main.cpp <<'SHIM_EOF'
// The entry point of GeneFuse: it reads every input first, as GeneFuse
// does, and refuses what GeneFuse would skip without a word, read out of
// bounds or misread, then runs GeneFuse.
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#include <map>
#include <string>
#include <vector>

int biochef_upstream_main(int argc, char *argv[]);

static void fail(const char *format, ...)
{
	va_list ap;
	va_start(ap, format);
	fputs("[genefuse] ", stderr);
	vfprintf(stderr, format, ap);
	fputc('\n', stderr);
	va_end(ap);
	exit(1);
}

static std::string shown(int c)
{
	char s[8];
	if (c >= 33 && c <= 126) snprintf(s, sizeof s, "'%c'", c);
	else snprintf(s, sizeof s, "0x%02X", c);
	return s;
}

// Reads a file line by line, gzip or not, without the line ends; a '\r'
// before the '\n' stays in the line
struct Lines {
	gzFile in;
	const char *path, *what;
	long number;
	std::string line;
	Lines(const char *path, const char *what) : path(path), what(what), number(0)
	{
		in = gzopen(path, "rb");
		if (!in) fail("cannot open %s, %s (%s)", path, what, strerror(errno));
	}
	~Lines() { gzclose(in); }
	bool next()
	{
		line.clear();
		int c;
		while ((c = gzgetc(in)) != -1 && c != '\n') line += (char)c;
		if (c == -1) {
			int error;
			gzerror(in, &error);
			if (error != Z_OK && error != Z_STREAM_END) fail("cannot read %s, %s", path, what);
			if (line.empty()) return false;
		}
		number++;
		if (memchr(line.data(), 0, line.size())) fail("line %ld of %s, %s, holds a NUL byte", number, path, what);
		return true;
	}
};

static bool gzipped(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) fail("cannot open %s (%s)", path, strerror(errno));
	int a = getc(f), b = getc(f);
	fclose(f);
	return a == 0x1f && b == 0x8b;
}

// GeneFuse reads a line of reads into 1000 bytes, with its line end
static const size_t FASTQ_LINE = 998;

// Reads FASTQ as GeneFuse does, four lines a read; returns the reads
static long check_reads(const char *path, const char *what)
{
	Lines in(path, what);
	long reads = 0;
	std::string name, seq;
	for (;;) {
		if (!in.next()) break;
		if (in.line.empty() || in.line == "\r") {
			// Blank lines at the end: GeneFuse reads four of them as a read
			long blank = in.number, blanks = 1;
			while (in.next()) {
				if (!in.line.empty() && in.line != "\r") fail("line %ld of %s, %s, is blank: a read is four lines, its name, bases, '+' and qualities", blank, path, what);
				blanks++;
			}
			if (blanks >= 4) fail("%s, %s, ends with %ld blank lines, which GeneFuse reads as a read with no bases", path, what, blanks);
			break;
		}
		for (int k = 0; k < 4; k++) {
			std::string &l = in.line;
			if (k && !in.next()) fail("%s, %s, ends within read %ld: a read is four lines, its name, bases, '+' and qualities", path, what, reads + 1);
			if (l.size() > FASTQ_LINE) fail("line %ld of %s, %s, is longer than %zu characters, which GeneFuse cannot read", in.number, path, what, FASTQ_LINE);
			if (!l.empty() && l[l.size() - 1] == '\r') l.erase(l.size() - 1);
			if (k == 0) {
				if (l.empty() || l[0] != '@') {
					if (!reads && !l.empty() && l[0] == '>') fail("%s, %s, is FASTA: GeneFuse reads FASTQ", path, what);
					fail("line %ld of %s, %s, should start read %ld with '@' and its name, and starts with %s", in.number, path, what, reads + 1, l.empty() ? "nothing" : shown((unsigned char)l[0]).c_str());
				}
				if (l.size() < 2 || isspace((unsigned char)l[1])) fail("read %ld of %s, %s, has no name", reads + 1, path, what);
				name = l.substr(1);
			} else if (k == 1) {
				if (l.empty()) fail("read %ld of %s, %s, %s, has no bases", reads + 1, path, what, name.c_str());
				for (size_t i = 0; i < l.size(); i++)
					if (!isalpha((unsigned char)l[i])) fail("read %ld of %s, %s, %s, has %s in its bases", reads + 1, path, what, name.c_str(), shown((unsigned char)l[i]).c_str());
				seq = l;
			} else if (k == 2) {
				if (l.empty() || l[0] != '+') fail("line %ld of %s, %s, should be '+' after the bases of read %ld, %s: GeneFuse reads each read's bases on one line", in.number, path, what, reads + 1, name.c_str());
			} else {
				if (l.size() != seq.size()) fail("read %ld of %s, %s, %s, has %zu qualities for %zu bases", reads + 1, path, what, name.c_str(), l.size(), seq.size());
				for (size_t i = 0; i < l.size(); i++)
					if (l[i] < 33 || l[i] > 126) fail("read %ld of %s, %s, %s, has %s in its qualities, which is not a quality from '!' to '~'", reads + 1, path, what, name.c_str(), shown((unsigned char)l[i]).c_str());
			}
		}
		reads++;
	}
	if (!reads) fail("%s, %s, holds no reads", path, what);
	return reads;
}

// Reads the reference as GeneFuse does: a sequence's name is its header up
// to the first space; returns each sequence's length
static std::map<std::string, size_t> check_reference(const char *path)
{
	const char *what = "the reference (-r)";
	if (gzipped(path)) fail("%s, %s, is compressed with gzip: GeneFuse reads the reference uncompressed", path, what);
	Lines in(path, what);
	std::map<std::string, size_t> lengths;
	std::string name;
	bool any = false;
	long blank = 0;
	while (in.next()) {
		std::string &l = in.line;
		// GeneFuse reads the line after a blank one as bases, even a header
		if (any && l.empty()) {
			if (!blank) blank = in.number;
			continue;
		}
		if (!l.empty() && l[l.size() - 1] == '\r') l.erase(l.size() - 1);
		if (blank) fail("line %ld of %s, %s, is blank: GeneFuse reads the line after a blank line as bases", blank, path, what);
		if (!l.empty() && l[0] == '>') {
			if (any && !lengths[name]) fail("sequence %s of %s, %s, has no bases", name.c_str(), path, what);
			name = l.substr(1, l.find(' ') == std::string::npos ? std::string::npos : l.find(' ') - 1);
			if (name.empty()) fail("line %ld of %s, %s, starts a sequence with no name", in.number, path, what);
			if (lengths.count(name)) fail("%s, %s, has two sequences named %s", path, what, name.c_str());
			lengths[name] = 0;
			any = true;
			continue;
		}
		if (!any) {
			if (l.find_first_not_of(" \t") == std::string::npos) continue;
			fail("%s, %s, is not FASTA: it should start with '>' and a name, and starts with %s", path, what, shown((unsigned char)l[l.find_first_not_of(" \t")]).c_str());
		}
		for (size_t i = 0; i < l.size(); i++)
			if (!isalpha((unsigned char)l[i])) fail("line %ld of %s, %s, has %s in sequence %s", in.number, path, what, shown((unsigned char)l[i]).c_str(), name.c_str());
		lengths[name] += l.size();
	}
	if (!any) fail("%s, %s, holds no sequences", path, what);
	if (!lengths[name]) fail("sequence %s of %s, %s, has no bases", name.c_str(), path, what);
	return lengths;
}

static std::string trimmed(const std::string &s)
{
	size_t a = s.find_first_not_of(' '), b = s.find_last_not_of(' ');
	return a == std::string::npos ? "" : s.substr(a, b - a + 1);
}

// A whole number from 0 to INT_MAX, as GeneFuse's atoi reads it
static bool number(const std::string &s, long &value)
{
	std::string t = trimmed(s);
	if (t.empty() || t.size() > 10 || t.find_first_not_of("0123456789") != std::string::npos) return false;
	value = strtol(t.c_str(), NULL, 10);
	return value <= INT_MAX;
}

static std::vector<std::string> fields(const std::string &s, char separator)
{
	std::vector<std::string> out(1);
	for (size_t i = 0; i < s.size(); i++) {
		if (s[i] == separator) out.push_back("");
		else out.back() += s[i];
	}
	return out;
}

// GeneFuse indexes each gene by its 16-mers
static const long KMER = 16;
// It reads a line of the fusion file into 4096 bytes, with its line end
static const size_t FUSION_LINE = 4094;

// Reads the fusion file as GeneFuse does, against the reference
static void check_fusions(const char *path, const std::map<std::string, size_t> &reference)
{
	const char *what = "the fusion file (-f)";
	if (gzipped(path)) fail("%s, %s, is compressed with gzip: GeneFuse reads it uncompressed", path, what);
	Lines in(path, what);
	std::map<std::string, long> missing;
	long found = 0;
	long genes = 0, gene_start = 0, gene_end = 0, exons = 0, last_id = 0, last_start = 0, last_end = 0;
	bool reversed = false;
	std::string gene;
	while (in.next()) {
		std::string l = in.line;
		if (l.size() > FUSION_LINE) fail("line %ld of %s, %s, is longer than %zu characters, which GeneFuse cannot read", in.number, path, what, FUSION_LINE);
		if (!l.empty() && l[l.size() - 1] == '\r') l.erase(l.size() - 1);
		l = trimmed(l);
		if (l.empty() || l[0] == '#') continue;
		if (l[0] == '>') {
			if (genes && !exons) fail("gene %s of %s, %s, has no exons", gene.c_str(), path, what);
			std::vector<std::string> f = fields(l, ',');
			std::vector<std::string> place = f.size() == 2 ? fields(f[1], ':') : std::vector<std::string>();
			std::vector<std::string> range = place.size() == 2 ? fields(place[1], '-') : std::vector<std::string>();
			if (range.size() != 2 || !number(range[0], gene_start) || !number(range[1], gene_end))
				fail("line %ld of %s, %s, should be a gene as >name,chromosome:start-end, and is \"%s\"", in.number, path, what, l.c_str());
			gene = trimmed(f[0].substr(1));
			std::string chr = trimmed(place[0]);
			if (gene.empty()) fail("line %ld of %s, %s, names no gene", in.number, path, what);
			if (gene == "invalid") fail("line %ld of %s, %s, names a gene invalid, which GeneFuse takes for no gene", in.number, path, what);
			if (chr.empty()) fail("gene %s of %s, %s, has no chromosome", gene.c_str(), path, what);
			for (size_t i = 0; i < gene.size() + chr.size(); i++) {
				unsigned char b = i < gene.size() ? gene[i] : chr[i - gene.size()];
				if (b < 32 || b > 126) fail("line %ld of %s, %s, has %s in the name of its gene or chromosome", in.number, path, what, shown(b).c_str());
			}
			// GeneFuse looks for the chromosome as named, with chr before
			// its name, then without chr
			std::map<std::string, size_t>::const_iterator c = reference.find(chr);
			if (c == reference.end()) c = reference.find("chr" + chr);
			if (c == reference.end()) {
				std::string bare = chr;
				for (size_t p; (p = bare.find("chr")) != std::string::npos;) bare.erase(p, 3);
				c = reference.find(bare);
			}
			if (gene_start < 1 || gene_end <= gene_start) fail("gene %s of %s, %s, should start at 1 or after, and end after it starts: it is %s:%ld-%ld", gene.c_str(), path, what, chr.c_str(), gene_start, gene_end);
			if (c == reference.end()) missing[chr]++;
			else found++;
			if (c != reference.end() && (size_t)gene_end > c->second) fail("gene %s of %s, %s, ends at %ld, past the end of %s in the reference, %zu bases long", gene.c_str(), path, what, gene_end, c->first.c_str(), c->second);
			if (gene_end - gene_start <= KMER) fail("gene %s of %s, %s, spans %ld bases: GeneFuse needs more than %ld to index it", gene.c_str(), path, what, gene_end - gene_start, KMER);
			genes++;
			exons = 0;
			continue;
		}
		if (!genes) fail("line %ld of %s, %s, should start a gene with '>', and is \"%s\"", in.number, path, what, l.c_str());
		std::vector<std::string> f = fields(l, ',');
		long id = 0, start = 0, end = 0;
		if (f.size() != 3 || !number(f[0], id) || !number(f[1], start) || !number(f[2], end))
			fail("line %ld of %s, %s, should be an exon of gene %s as number,start,end, and is \"%s\"", in.number, path, what, gene.c_str(), l.c_str());
		if (start > end) fail("exon %ld of gene %s in %s, %s, ends before it starts", id, gene.c_str(), path, what);
		if (start < gene_start || end > gene_end) fail("exon %ld of gene %s in %s, %s, %ld-%ld, is not within the gene, %ld-%ld", id, gene.c_str(), path, what, start, end, gene_start, gene_end);
		if (exons && id != last_id + 1) fail("exon %ld of gene %s in %s, %s, follows exon %ld: GeneFuse numbers introns after the exons, which go up by one", id, gene.c_str(), path, what, last_id);
		if (!exons && id < 1) fail("gene %s in %s, %s, numbers its first exon 0: exons are numbered from 1", gene.c_str(), path, what);
		// GeneFuse takes a gene as reversed when its second exon starts
		// before its first, and finds introns between exons in that order
		if (exons == 1) reversed = start < last_start;
		if (exons && (reversed ? end >= last_start : start <= last_end))
			fail("exon %ld of gene %s in %s, %s, overlaps exon %ld or is out of order: the exons of a gene go along the gene, or the other way on the reverse strand", id, gene.c_str(), path, what, last_id);
		last_id = id;
		last_start = start;
		last_end = end;
		exons++;
	}
	if (!genes) fail("%s, %s, lists no genes", path, what);
	if (!exons) fail("gene %s of %s, %s, has no exons", gene.c_str(), path, what);
	// A fusion file lists genes on every chromosome, and a reference may
	// hold only some: GeneFuse looks for the fusions of the genes it holds
	std::string list;
	for (std::map<std::string, long>::const_iterator m = missing.begin(); m != missing.end(); ++m) {
		char n[32];
		snprintf(n, sizeof n, " (%ld)", m->second);
		list += (list.empty() ? "" : ", ") + m->first + n;
	}
	if (!found) fail("none of the genes of %s, %s, is on a sequence of the reference: they are on %s", path, what, list.c_str());
	if (!missing.empty()) fprintf(stderr, "[genefuse] %ld of the %ld genes of %s are on sequences not in the reference, and their fusions are not looked for: %s\n", genes - found, genes, path, list.c_str());
}

static bool integer(const char *s, long low, long high, long &value)
{
	char *end;
	errno = 0;
	if (!*s || isspace((unsigned char)*s)) return false;
	long long v = strtoll(s, &end, 10);
	if (*end || errno || v < low || v > high) return false;
	value = (long)v;
	return true;
}

int main(int argc, char *argv[])
{
	struct Option { const char *shorter, *longer; bool value; const char *given; };
	Option options[] = {
		{ "-1", "--read1", true, NULL }, { "-2", "--read2", true, NULL }, { "-f", "--fusion", true, NULL }, { "-r", "--ref", true, NULL },
		{ "-u", "--unique", true, NULL }, { "-h", "--html", true, NULL }, { "-j", "--json", true, NULL }, { "-t", "--thread", true, NULL },
		{ "-d", "--deletion", true, NULL }, { "-D", "--output_deletions", false, NULL }, { "-U", "--output_untranslated_fusions", false, NULL },
	};
	const int count = sizeof options / sizeof *options;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-?") || !strcmp(argv[i], "--help")) return biochef_upstream_main(argc, argv);
		Option *o = NULL;
		for (int k = 0; k < count && !o; k++)
			if (!strcmp(argv[i], options[k].shorter) || !strcmp(argv[i], options[k].longer)) o = &options[k];
		if (!o) fail(argv[i][0] == '-' ? "unknown option %s" : "unexpected argument \"%s\": the reads are given with -1 and -2", argv[i]);
		if (o->given) fail("%s is given twice", o->longer);
		if (o->value && i + 1 >= argc) fail("%s needs a value", argv[i]);
		o->given = o->value ? argv[++i] : "";
	}
	const char *read1 = options[0].given, *read2 = options[1].given, *fusion = options[2].given, *ref = options[3].given;
	if (!read1) fail("the reads are needed, with -1 (and -2 for the second reads of pairs)");
	if (!fusion) fail("the fusion file is needed, with -f");
	if (!ref) fail("the reference is needed, with -r");
	long value;
	if (options[4].given && !integer(options[4].given, 1, INT_MAX, value)) fail("--unique should be a whole number from 1, the reads that must support a fusion, and is \"%s\"", options[4].given);
	if (options[7].given && !integer(options[7].given, 1, 1024, value)) fail("--thread should be a whole number from 1 to 1024, and is \"%s\"", options[7].given);
	if (options[8].given && !integer(options[8].given, 0, INT_MAX, value)) fail("--deletion should be a whole number from 0, the shortest deletion to report, and is \"%s\"", options[8].given);
	for (int k = 5; k <= 6; k++)
		if (options[k].given && !*options[k].given) fail("%s needs a file name", options[k].longer);

	std::map<std::string, size_t> reference = check_reference(ref);
	check_fusions(fusion, reference);
	long reads1 = check_reads(read1, read2 ? "the first reads (-1)" : "the reads (-1)");
	if (read2) {
		long reads2 = check_reads(read2, "the second reads (-2)");
		if (reads1 != reads2) fail("the first reads (-1) hold %ld reads and the second reads (-2) %ld: they should be the two reads of the same pairs", reads1, reads2);
	}
	// GeneFuse writes its command line in its reports: the same in every
	// runtime
	argv[0] = (char *)"genefuse";
	return biochef_upstream_main(argc, argv);
}
SHIM_EOF
sed -i 's/^int main(int argc, char\* argv\[\]){$/int biochef_upstream_main(int argc, char* argv[]){/' src/main.cpp
grep -q '^int biochef_upstream_main(int argc, char\* argv\[\]){$' src/main.cpp
# main ends without a return, which only main may do.
sed -i 's/^    loginfo("done");$/&\n    return 0;/' src/main.cpp
grep -q '^    return 0;$' src/main.cpp
cat > src/biochef_genefuse.h <<'H_EOF'
#include <stdint.h>
#include <stdio.h>
#include <string>

// A string as a JSON string's contents
static inline std::string biochef_json(const std::string &s)
{
	std::string out;
	for (size_t i = 0; i < s.size(); i++) {
		unsigned char c = s[i];
		if (c == '"' || c == '\\') {
			out += '\\';
			out += (char)c;
		} else if (c < 0x20) {
			char u[8];
			snprintf(u, sizeof u, "\\u%04x", c);
			out += u;
		} else {
			out += (char)c;
		}
	}
	return out;
}
H_EOF

# The scanners read the reads in one thread and match them in others, so
# the matches come in an order that changes from run to run, and with it
# which reads support which fusion. Each pack of reads is now matched as
# soon as it is read, natively as in wasm, which cannot start threads.
for f in pe:PairEnd se:SingleEnd; do
    file=src/${f%%:*}scanner.cpp; cls=${f#*:}
    sed -i -e "s|^    std::thread producer(std::bind(&${cls}Scanner::producerTask, this));\$|    producerTask();\n    mThreadNum = 0;|" \
      -e '/^    producer.join();$/d' \
      -e "s|^void ${cls}Scanner::producePack(.*){\$|&\n    scan${cls}(pack);\n    return;|" $file
    grep -q '^    producerTask();$' $file
    ! grep -q 'producer.join\|std::thread producer' $file
    [ "$(grep -c "^    scan${cls}(pack);$" $file)" -eq 1 ]
done
# Matches and fusions of the same rank keep their order (stable_sort).
sed -i 's/^\( *\)sort(/\1std::stable_sort(/' src/fusionmapper.cpp
[ "$(grep -c 'std::stable_sort(' src/fusionmapper.cpp)" -eq 2 ]

# GeneFuse packs a contig and a position into a long, and its edit
# distance shifts 1L by up to 63: long is 32 bits in wasm32.
sed -i 's/^typedef long int64;$/typedef int64_t int64;/; s/^typedef unsigned long uint64;$/typedef uint64_t uint64;/' src/common.h
sed -i -E 's/\blong\b/int64_t/g' src/editdistance.cpp src/fusionresult.cpp src/htmlreporter.cpp src/indexer.h src/indexer.cpp src/matcher.h src/matcher.cpp
sed -i -E 's/\b1L\b/1LL/g' src/editdistance.cpp
[ "$(cat src/common.h src/editdistance.cpp src/fusionresult.cpp src/htmlreporter.cpp src/indexer.h src/indexer.cpp src/matcher.h src/matcher.cpp | grep -cwE 'long|1L')" -eq 0 ]
sed -i 's|time used: %ld seconds\\n", FUSIONSCAN_VER, (t2-t1));|time used: %ld seconds\\n", FUSIONSCAN_VER, (long)(t2-t1));|' src/main.cpp
grep -q '(long)(t2-t1)' src/main.cpp

# The k-mer loops subtract 16 from an unsigned length: a contig or a read
# shorter than that sends them far past its end.
sed -i 's/for(int i=0; i<seq.length() - KMER; ++i) {/for(int i=0; i<(int)seq.length() - KMER; ++i) {/' src/indexer.cpp src/matcher.cpp
sed -i 's/for(int i=0;i<str.length()-KMER+1;++i){/for(int i=0;i<(int)str.length()-KMER+1;++i){/' src/matcher.cpp
[ "$(cat src/indexer.cpp src/matcher.cpp | grep -c '(int)s[a-z]*.length() *- *KMER')" -eq 3 ]
# Arrays from new[] are freed with delete[].
sed -i -E 's/^( *)delete (mBloomFilter|mBloomFilterArray|mask|skipped|allKmer|kmerValid|pack->data|mRepo\.packBuffer|data);$/\1delete[] \2;/' src/indexer.cpp src/matcher.cpp src/pescanner.cpp src/sescanner.cpp
[ "$(cat src/indexer.cpp src/matcher.cpp src/pescanner.cpp src/sescanner.cpp | grep -c 'delete\[\]')" -eq 17 ]
# Without chr, a chromosome's name was its name past the first c.
sed -i 's/^        pos_begin = pos + 1;$/        pos_begin = pos + src.length();/' src/util.h
grep -q 'pos_begin = pos + src.length();' src/util.h

# Reads are read by their content, gzip or not, whatever the file's name.
sed -i 's/^\tif (isZipFastq(mFilename)){$/\tif (true){/' src/fastqreader.cpp
grep -q '^	if (true){$' src/fastqreader.cpp
# The reference's names end at a '\r' too, and a line's first character
# is kept only as a base, as the rest of the line is.
sed -i -e 's/^                ssSeq << c;$/                if(isalpha(c) || c == '"'-'"' || c == '"'*'"') ssSeq << c;/' \
  -e "s/^    string header = ssHeader.str();\$/&\n    if(!header.empty() \&\& header[header.size()-1] == '\\\\r') header.erase(header.size()-1);/" src/fastareader.cpp
grep -q "if(isalpha(c) || c == '-' || c == '\*') ssSeq << c;" src/fastareader.cpp
grep -qF "header[header.size()-1] == '\r') header.erase" src/fastareader.cpp

# The JSON report holds the command line, the genes' names and the reads'
# qualities, which can hold '"' and '\', as JSON strings.
sed -i -E -e 's/<< command <</<< biochef_json(command) <</' -e 's/<< +(fusion\.(mTitle|m(Left|Right)Pos|m(Left|Right)Gene\.m(Name|Chr))) <</<< biochef_json(\1) <</g' src/jsonreporter.cpp
[ "$(grep -o 'biochef_json(' src/jsonreporter.cpp | wc -l)" -eq 8 ]
sed -i '/"\\"qual\\":"/s/mRead->mQuality/biochef_json(mRead->mQuality)/' src/match.cpp
grep -q 'biochef_json(mRead->mQuality)' src/match.cpp

FLAGS="-std=c++11 -O2 -ffp-contract=off -I./inc -include src/biochef_genefuse.h"

make CC=g++ CFLAGS="$FLAGS -Wall" -j4
