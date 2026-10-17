set -eo pipefail

cd core

# BioChef runs each MAFFT binary as one operation, in a file system shared by
# the tools of a workflow. The binaries read and write their intermediate
# results under fixed names (hat2, hat3, pre...), which the mafft script
# creates, chains and deletes. This entry point, linked into every binary,
# does that part of the script's job before the binary's own main runs.
cat > biochef_main.c <<'EOF'
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int mafft_main(int argc, char *argv[]);

/* Working files of the binaries. Removed first, so that a file left by an
 * earlier run in the same workflow is never read as this run's own. */
static const char *working_files[] = {
	"hat2", "hat2i", "hat2n", "hat3", "hat3.seed", "hat4", "hatx", "pre",
	"order", "trace", "infile", "infile.tree", "_deletelist", "_deletemap",
	"hat2-1", "hat2-2", "_bc_in", "_bc_out", NULL
};

/* Distances (hat2) and local alignments (hat3) pass from one operation to the
 * next. Each operation writes them with a first line naming the sequences
 * they were computed from, and reads only those of its own sequences. */
enum { HAT2, HAT3 };
static const struct { const char *option, *name; int kind; } named_inputs[] = {
	{ "--bc-hat2", "hat2", HAT2 }, { "--bc-hat2i", "hat2i", HAT2 },
	{ "--bc-hat2n", "hat2n", HAT2 }, { "--bc-hat3", "hat3", HAT3 },
	{ NULL, NULL, 0 }
};
static const char *kind_names[] = { "hat2", "hat3" };

static void fail(const char *format, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void fail(const char *format, ...)
{
	va_list ap;
	fputs("[mafft] ", stderr);
	va_start(ap, format);
	vfprintf(stderr, format, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

static FILE *open_or_fail(const char *path, const char *mode)
{
	FILE *fp = fopen(path, mode);
	if (!fp) fail("cannot %s %s", *mode == 'r' ? "read" : "write", path);
	return fp;
}

static void close_or_fail(FILE *fp, const char *path)
{
	if (fclose(fp)) fail("cannot write %s", path);
}

/* Appends src to dst. Like the mafft script, sequence files have \r turned
 * into \n (TEXT), and the sequences to add also lose their empty lines and
 * end with a newline (ADD). Returns the number of lines starting with '>',
 * which is the number of sequences in a FASTA file. */
enum { RAW, TEXT, ADD };
static int append(FILE *dst, FILE *in, int how)
{
	int c, last = '\n', n = 0;
	while ((c = getc(in)) != EOF) {
		if (how != RAW && c == '\r') c = '\n';
		if (how == ADD && c == '\n' && last == '\n') continue;
		if (c == '>' && last == '\n') ++n;
		putc(c, dst);
		last = c;
	}
	if (how == ADD && last != '\n') putc('\n', dst);
	return n;
}

static int append_file(FILE *dst, const char *src, int how)
{
	FILE *in = open_or_fail(src, "rb");
	int n = append(dst, in, how);
	fclose(in);
	return n;
}

/* The sequences of this run: their names and their lengths without gaps. */
static struct seq { char *name; long length; } *seqs;
static int nseqs;
static char signature[17];

static void read_seqs(const char *path)
{
	FILE *fp = open_or_fail(path, "rb");
	char line[4096];
	int at_line_start = 1, in_name = 0, i;
	uint64_t h = 14695981039346656037ULL;
	while (fgets(line, sizeof line, fp)) {
		size_t len = strlen(line);
		int whole = len && line[len - 1] == '\n';
		if (at_line_start && line[0] == '>') {
			seqs = realloc(seqs, (nseqs + 1) * sizeof *seqs);
			if (!seqs) fail("out of memory");
			line[strcspn(line, "\n")] = 0;
			seqs[nseqs].name = strdup(line + 1);
			seqs[nseqs++].length = 0;
			in_name = 1;
		} else if (nseqs && in_name) {
			/* the rest of a name longer than the buffer */
			char *name = seqs[nseqs - 1].name;
			line[strcspn(line, "\n")] = 0;
			name = realloc(name, strlen(name) + strlen(line) + 1);
			if (!name) fail("out of memory");
			seqs[nseqs - 1].name = strcat(name, line);
		} else if (nseqs) {
			char *p;
			for (p = line; *p; ++p)
				if (*p != '-' && *p != ' ' && *p != '\t' && *p != '\n') ++seqs[nseqs - 1].length;
		}
		if (whole) in_name = 0;
		at_line_start = whole;
	}
	fclose(fp);
	/* FNV-1a over each name and length */
	for (i = 0; i < nseqs; ++i) {
		char buf[32];
		const char *p;
		snprintf(buf, sizeof buf, "\n%ld\n", seqs[i].length);
		for (p = seqs[i].name; *p; ++p) h = (h ^ (unsigned char)*p) * 1099511628211ULL;
		for (p = buf; *p; ++p) h = (h ^ (unsigned char)*p) * 1099511628211ULL;
	}
	snprintf(signature, sizeof signature, "%016llx", (unsigned long long)h);
}

static void header(char *buf, size_t size, int kind)
{
	snprintf(buf, size, "# BioChef MAFFT %s of %d sequences, signature %s\n", kind_names[kind], nseqs, signature);
}

/* A distance matrix: its sequences, listed as "   1. =name", must be the
 * first sequences of this run, in order. MAFFT checks their number itself. */
static void check_hat2(const char *path)
{
	FILE *fp = open_or_fail(path, "rb");
	char line[4096];
	int i, n = 0, index;
	if (!fgets(line, sizeof line, fp) || !fgets(line, sizeof line, fp) || sscanf(line, "%d", &n) != 1
	    || n < 1 || n > nseqs || !fgets(line, sizeof line, fp))
		fail("%s is not a MAFFT distance matrix", path);
	for (i = 0; i < n; ++i) {
		char *name = NULL;
		if (!fgets(line, sizeof line, fp) || sscanf(line, "%d.", &index) != 1 || index != i + 1
		    || !(name = strstr(line, ". =")))
			fail("%s is not a MAFFT distance matrix", path);
		name += 3;
		name[strcspn(name, "\n")] = 0;
		if (!*name || strncmp(seqs[i].name, name, strlen(name)))
			fail("%s is the distance matrix of other sequences: its sequence %d is not %s", path, i + 1, seqs[i].name);
	}
	fclose(fp);
}

/* Local alignments: each line pairs sequences i < j of this run, with each
 * region inside its sequence. MAFFT trusts these numbers as array indices. */
static void check_hat3(const char *path)
{
	FILE *fp = open_or_fail(path, "rb");
	char line[4096], tag;
	int i, j, overlap, start1, end1, start2, end2, number = 0;
	double score;
	while (fgets(line, sizeof line, fp)) {
		++number;
		if (line[strspn(line, " \t\n")] == 0) continue;
		if (sscanf(line, "%d %d %d %lf %d %d %d %d %c", &i, &j, &overlap, &score,
		           &start1, &end1, &start2, &end2, &tag) != 9)
			fail("%s is not a MAFFT local alignment table (line %d)", path, number);
		if (i < 0 || j <= i || j >= nseqs || start1 < 0 || start1 > end1 || end1 >= seqs[i].length
		    || start2 < 0 || start2 > end2 || end2 >= seqs[j].length)
			fail("%s holds the local alignments of other sequences (line %d)", path, number);
	}
	fclose(fp);
}

/* Copies a distances or local alignments input to the name the binary opens,
 * once its first line shows it was made from this run's sequences. One with
 * nothing after that line stands for a file the binary did not write. */
static void take_input(int j, const char *path)
{
	FILE *in = open_or_fail(path, "rb"), *out;
	char line[256], expected[256];
	int c;
	header(expected, sizeof expected, named_inputs[j].kind);
	if (!fgets(line, sizeof line, in) || strncmp(line, "# BioChef MAFFT ", 16))
		fail("%s is not %s written by a MAFFT operation", named_inputs[j].option,
		     named_inputs[j].kind == HAT2 ? "distances" : "local alignments");
	if (strcmp(line, expected))
		fail("%s was computed from other sequences than these", named_inputs[j].option);
	if ((c = getc(in)) == EOF) {
		fclose(in);
		return;
	}
	ungetc(c, in);
	out = open_or_fail(named_inputs[j].name, "wb");
	append(out, in, RAW);
	close_or_fail(out, named_inputs[j].name);
	fclose(in);
	if (named_inputs[j].kind == HAT2) check_hat2(named_inputs[j].name);
	else check_hat3(named_inputs[j].name);
}

/* Outputs given with --bc-output. After a run that succeeds, each gets the
 * first line naming this run's sequences, and one the binary did not write,
 * as tbfast writes no distances for a single sequence, is created with
 * nothing else. After a failure they are left as they are, unmarked, so
 * that no operation takes them. */
static int outputs[2], noutputs, status = -1;

void biochef_exit(int code) __attribute__((noreturn));
void biochef_exit(int code)
{
	status = code;
	exit(code);
}

/* Runs at exit, where exit() must not be called again: errors end the
 * process with _exit(). */
static void mark_outputs(void)
{
	int i;
	char line[256];
	if (status != 0) return;
	for (i = 0; i < noutputs; ++i) {
		const char *name = kind_names[outputs[i]];
		FILE *out = fopen("_bc_out", "wb"), *in;
		if (!out) break;
		header(line, sizeof line, outputs[i]);
		fputs(line, out);
		if ((in = fopen(name, "rb"))) {
			append(out, in, RAW);
			fclose(in);
		}
		if (fclose(out) || rename("_bc_out", name)) break;
	}
	if (i < noutputs) {
		fprintf(stderr, "[mafft] cannot write %s\n", kind_names[outputs[i]]);
		_exit(1);
	}
}

int main(int argc, char *argv[])
{
	const char *in = NULL, *add = NULL, *given[sizeof named_inputs / sizeof *named_inputs] = { NULL };
	char **args = calloc(argc + 3, sizeof(char *));
	static char count[16];
	int i, j, n = 0;

	for (i = 0; working_files[i]; ++i) unlink(working_files[i]);

	args[n++] = argv[0];
	for (i = 1; i < argc; ++i) {
		for (j = 0; named_inputs[j].option && strcmp(argv[i], named_inputs[j].option); ++j);
		if (!named_inputs[j].option && strcmp(argv[i], "--bc-in") && strcmp(argv[i], "--bc-add")
		    && strcmp(argv[i], "--bc-output")) {
			args[n++] = argv[i];
			continue;
		}
		if (i + 1 >= argc) fail("%s needs a value", argv[i]);
		if (named_inputs[j].option) given[j] = argv[i + 1];
		else if (!strcmp(argv[i], "--bc-in")) in = argv[i + 1];
		else if (!strcmp(argv[i], "--bc-add")) add = argv[i + 1];
		else {
			int kind = !strcmp(argv[i + 1], "hat2") ? HAT2 : !strcmp(argv[i + 1], "hat3") ? HAT3 : -1;
			if (kind < 0) fail("--bc-output takes hat2 or hat3");
			if (noutputs == 2) fail("too many --bc-output");
			outputs[noutputs++] = kind;
		}
		++i;
	}
	if (add && !in) fail("--bc-add needs --bc-in");
	if (noutputs && !in) fail("--bc-output needs --bc-in");

	/* The sequences, as the mafft script writes its infile: the input, an
	 * empty line, and with --add the sequences to add, whose number goes to
	 * the binary with -I. */
	if (in) {
		FILE *out = open_or_fail("_bc_in", "wb");
		append_file(out, in, TEXT);
		putc('\n', out);
		if (add) {
			snprintf(count, sizeof count, "%d", append_file(out, add, ADD));
			args[n++] = "-I";
			args[n++] = count;
		}
		close_or_fail(out, "_bc_in");
		read_seqs("_bc_in");
		if (!freopen("_bc_in", "rb", stdin)) fail("cannot read _bc_in");
	}

	for (j = 0; named_inputs[j].option; ++j) {
		if (!given[j]) continue;
		if (!in) fail("%s needs --bc-in", named_inputs[j].option);
		take_input(j, given[j]);
	}

	if (noutputs && atexit(mark_outputs)) fail("cannot register the outputs");
	args[n] = NULL;
	status = mafft_main(n, args);
	return status;
}
EOF
emcc -O2 -c biochef_main.c -o biochef_main.o

# Built with -Denablemultithread, MAFFT runs its distance and tree stages in
# pthread_create workers even with one thread. Without pthreads in wasm those
# workers never run and the alignment comes out wrong, so build the serial
# code path instead.
grep -qP '^\tENABLE_MULTITHREAD = -Denablemultithread' Makefile
emmake make all ENABLE_MULTITHREAD= CC=emcc CFLAGS="-O2 -Dmain=mafft_main -Dexit=biochef_exit -Wno-deprecated-non-prototype -Wno-implicit-function-declaration -Wno-int-conversion" LIBS="biochef_main.o -lm $EM_FLAGS -sSTACK_SIZE=8MB" -j4

mkdir -p out

for b in disttbfast tbfast dvtditr dndpre pairlocalalign addsingle splittbfast mafft-profile mafft-distance f2cl; do mv "$b" "out/$b.js" && mv "$b.wasm" "out/$b.wasm"; done
