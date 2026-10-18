set -eo pipefail

# main.c skips the rows of the wrong width, reads what is not a number as 0,
# and lets t-SNE crash or give NaN on tables it cannot embed. This entry
# point, linked in place of main.c, reads the table strictly and refuses what
# t-SNE cannot embed, then embeds it as main.c does. The same entry point is
# in build-native.sh.
cat > biochef_main.c <<'SHIM_EOF'
/* BioChef's entry point for bhtsne, linked in place of main.c. main.c skips
 * the rows of the wrong width and reads what is not a number as 0, and
 * t-SNE gives NaN, or overflows its buffers, on tables and parameters it
 * cannot embed. This one reads the SND table strictly, refuses what t-SNE
 * cannot embed with a message, and then embeds and prints the table as
 * main.c does. */

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#include "t-sne.h"

/* With theta above 0, SPTree splits each cell in 2^dimensions children */
#define MAX_TREE_DIM 8

static void fail(const char *fmt, ...)
{
	va_list ap;
	fprintf(stderr, "[bhtsne] ");
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(1);
}

/* The build renames t-SNE's calls to rand, srand, exp and log to these, so
 * that a seed gives the same embedding in every runtime: libm's exp and log
 * differ in the last bit between glibc, glibc on a CPU with FMA, and wasm,
 * and t-SNE grows that bit over its iterations. rand and srand are glibc's
 * (random_r, TYPE_3); exp and log are fdlibm's, as musl had them. */
static int32_t rand_state[31];
static int rand_front, rand_rear;

int biochef_rand(void)
{
	uint32_t v = (uint32_t)rand_state[rand_front] + (uint32_t)rand_state[rand_rear];
	rand_state[rand_front] = (int32_t)v;
	rand_front = (rand_front + 1) % 31;
	rand_rear = (rand_rear + 1) % 31;
	return (int)(v >> 1);
}

void biochef_srand(unsigned int seed)
{
	int32_t word;
	int i;
	if (seed == 0) seed = 1;
	word = rand_state[0] = (int32_t)seed;
	for (i = 1; i < 31; ++i) {
		int32_t hi = word / 127773, lo = word % 127773;
		word = 16807 * lo - 2836 * hi;
		if (word < 0) word += 2147483647;
		rand_state[i] = word;
	}
	rand_front = 3, rand_rear = 0;
	for (i = 0; i < 310; ++i) biochef_rand();
}

static uint64_t bits(double x) { uint64_t u; memcpy(&u, &x, 8); return u; }
static double from_bits(uint64_t u) { double x; memcpy(&x, &u, 8); return x; }

static double scale2(double y, int n)
{
	if (n > 1023) {
		y *= 0x1p1023, n -= 1023;
		if (n > 1023) {
			y *= 0x1p1023, n -= 1023;
			if (n > 1023) n = 1023;
		}
	} else if (n < -1022) {
		/* n ends below -53, against double rounding among the subnormals */
		y *= 0x1p-1022 * 0x1p53, n += 1022 - 53;
		if (n < -1022) {
			y *= 0x1p-1022 * 0x1p53, n += 1022 - 53;
			if (n < -1022) n = -1022;
		}
	}
	return y * from_bits((uint64_t)(0x3ff + n) << 52);
}

double biochef_exp(double x)
{
	static const double half[2] = { 0.5, -0.5 },
		ln2hi = 6.93147180369123816490e-01, ln2lo = 1.90821492927058770002e-10,
		invln2 = 1.44269504088896338700e+00,
		P1 = 1.66666666666666019037e-01, P2 = -2.77777777770155933842e-03,
		P3 = 6.61375632143793436117e-05, P4 = -1.65339022054652515390e-06,
		P5 = 4.13813679705723846039e-08;
	double hi, lo, c, xx, y;
	int k, sign;
	uint32_t hx = (uint32_t)(bits(x) >> 32);

	sign = hx >> 31;
	hx &= 0x7fffffff;
	if (hx >= 0x4086232b) { /* |x| >= 708.39 */
		if (isnan(x)) return x;
		if (x > 709.782712893383973096) return x * 0x1p1023;
		if (x < -745.13321910194110842) return 0;
	}
	if (hx > 0x3fd62e42) { /* |x| > ln2 / 2 */
		if (hx >= 0x3ff0a2b2) /* |x| >= 1.5 ln2 */
			k = (int)(invln2 * x + half[sign]);
		else
			k = 1 - sign - sign;
		hi = x - k * ln2hi;
		lo = k * ln2lo;
		x = hi - lo;
	} else if (hx > 0x3e300000) { /* |x| > 2^-28 */
		k = 0, hi = x, lo = 0;
	} else {
		return 1 + x;
	}
	xx = x * x;
	c = x - xx * (P1 + xx * (P2 + xx * (P3 + xx * (P4 + xx * P5))));
	y = 1 + (x * c / (2 - c) - lo + hi);
	return k == 0 ? y : scale2(y, k);
}

double biochef_log(double x)
{
	static const double ln2_hi = 6.93147180369123816490e-01, ln2_lo = 1.90821492927058770002e-10,
		Lg1 = 6.666666666666735130e-01, Lg2 = 3.999999999940941908e-01,
		Lg3 = 2.857142874366239149e-01, Lg4 = 2.222219843214978396e-01,
		Lg5 = 1.818357216161805012e-01, Lg6 = 1.531383769920937332e-01,
		Lg7 = 1.479819860511658591e-01;
	uint64_t u = bits(x);
	double hfsq, f, s, z, R, w, t1, t2, dk;
	uint32_t hx = (uint32_t)(u >> 32);
	int k = 0;

	if (hx < 0x00100000 || hx >> 31) {
		if (u << 1 == 0) return -1 / (x * x); /* log(0) = -inf */
		if (hx >> 31) return (x - x) / 0.0;   /* log(-x) = NaN */
		k -= 54, x *= 0x1p54; /* subnormal */
		u = bits(x);
		hx = (uint32_t)(u >> 32);
	} else if (hx >= 0x7ff00000) {
		return x;
	} else if (hx == 0x3ff00000 && u << 32 == 0) {
		return 0;
	}
	/* x into [sqrt(2)/2, sqrt(2)] */
	hx += 0x3ff00000 - 0x3fe6a09e;
	k += (int)(hx >> 20) - 0x3ff;
	hx = (hx & 0x000fffff) + 0x3fe6a09e;
	x = from_bits((uint64_t)hx << 32 | (u & 0xffffffff));
	f = x - 1.0;
	hfsq = 0.5 * f * f;
	s = f / (2.0 + f);
	z = s * s;
	w = z * z;
	t1 = w * (Lg2 + w * (Lg4 + w * Lg6));
	t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
	R = t2 + t1;
	dk = k;
	return s * (hfsq + R) + dk * ln2_lo - hfsq + f + dk * ln2_hi;
}

static void *xrealloc(void *p, size_t n)
{
	p = realloc(p, n ? n : 1);
	if (!p) fail("out of memory");
	return p;
}

static void usage(void)
{
	fprintf(stderr, "Usage: bhtsne [options] <in.snd>\n");
	fprintf(stderr, "Options:\n");
	fprintf(stderr, "  -d INT      output dimension, at most %d with theta above 0 [2]\n", MAX_TREE_DIM);
	fprintf(stderr, "  -e FLOAT    step size (theta), 0 for exact t-SNE [0.5]\n");
	fprintf(stderr, "  -p FLOAT    perplexity [50]\n");
	fprintf(stderr, "  -s INT      random seed, negative for the time [11]\n");
	exit(1);
}

static int parse_int(const char *opt, const char *s)
{
	char *end;
	long v;
	errno = 0;
	v = strtol(s, &end, 10);
	if (!*s || *end || errno || v < INT_MIN || v > INT_MAX)
		fail("%s takes an integer, not '%s'", opt, s);
	return (int)v;
}

static double parse_double(const char *opt, const char *s)
{
	char *end;
	double v;
	errno = 0;
	v = strtod(s, &end);
	if (!*s || *end || errno || !isfinite(v))
		fail("%s takes a number, not '%s'", opt, s);
	return v;
}

/* A value as the hub's SND type takes it: [+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)? */
static int is_number(const char *s)
{
	int digits = 0;
	if (*s == '+' || *s == '-') ++s;
	while (*s >= '0' && *s <= '9') ++s, ++digits;
	if (*s == '.') {
		++s;
		while (*s >= '0' && *s <= '9') ++s, ++digits;
	}
	if (!digits) return 0;
	if (*s == 'e' || *s == 'E') {
		++s;
		if (*s == '+' || *s == '-') ++s;
		if (!(*s >= '0' && *s <= '9')) return 0;
		while (*s >= '0' && *s <= '9') ++s;
	}
	return *s == 0;
}

static char *read_all(const char *path, size_t *len)
{
	gzFile fp = gzopen(path, "rb");
	char *buf = NULL;
	size_t n = 0, cap = 0;
	int r;
	if (!fp) fail("cannot open %s", path);
	for (;;) {
		if (cap - n < 65536) {
			if (cap > SIZE_MAX / 2) fail("%s is too large", path);
			cap = cap ? cap * 2 : 1 << 20;
			buf = xrealloc(buf, cap + 1);
		}
		r = gzread(fp, buf + n, (unsigned)(cap - n < 65536 ? cap - n : 65536));
		if (r < 0) fail("cannot read %s", path);
		if (r == 0) break;
		n += (size_t)r;
	}
	gzclose(fp);
	if (memchr(buf, 0, n)) fail("%s is not an SND table: it holds a NUL byte", path);
	buf[n] = 0;
	*len = n;
	return buf;
}

int main(int argc, char *argv[])
{
	int seed = 11, out_dim = 2, n = 0, n_col = -1, i, j, line_no = 0;
	double perplexity = 50., theta = .5, *x = NULL, *y;
	char **names = NULL, *buf, *line, *next;
	const char *path = NULL;
	size_t len, x_cap = 0, n_cap = 0;

	for (i = 1; i < argc; ++i) {
		const char *a = argv[i];
		if (a[0] == '-' && a[1] && strchr("spde", a[1])) {
			const char *v = a[2] ? a + 2 : (i + 1 < argc ? argv[++i] : NULL);
			char opt[3] = { '-', a[1], 0 };
			if (!v) fail("%s needs a value", opt);
			if (a[1] == 's') seed = parse_int(opt, v);
			else if (a[1] == 'd') out_dim = parse_int(opt, v);
			else if (a[1] == 'p') perplexity = parse_double(opt, v);
			else theta = parse_double(opt, v);
		} else if (a[0] == '-' && a[1]) {
			fail("unknown option %s", a);
		} else if (!path) {
			path = a;
		} else {
			fail("one SND table only, not '%s' too", a);
		}
	}
	if (!path) usage();
	if (theta < 0) fail("theta (-e) must be 0 or above, not %g", theta);
	if (out_dim < 1) fail("the output dimension (-d) must be 1 or more, not %d", out_dim);
	if (theta > 0 && out_dim > MAX_TREE_DIM)
		fail("the output dimension (-d) must be at most %d with theta (-e) above 0, not %d", MAX_TREE_DIM, out_dim);
	if (!(perplexity > 0)) fail("the perplexity (-p) must be above 0, not %g", perplexity);
	/* bhtsne finds the 3 * perplexity nearest neighbours of each sample */
	if (theta > 0 && (int)(3 * perplexity) < 1)
		fail("the perplexity (-p) must be at least 1/3 with theta (-e) above 0, not %g", perplexity);

	/* Like the hub's SND type: lines starting with '#' and blank lines are
	 * skipped; every other line, without its trailing CRs, is a name and as
	 * many values as the first */
	buf = read_all(path, &len);
	line = buf;
	if (!strncmp(line, "\xef\xbb\xbf", 3)) line += 3; /* a UTF-8 byte order mark */
	for (; line && *line; line = next) {
		char *end, *field, *tab;
		int k;
		++line_no;
		next = strchr(line, '\n');
		end = next ? next : line + strlen(line);
		if (next) *next++ = 0;
		while (end > line && end[-1] == '\r') *--end = 0;
		if (line[0] == '#') continue;
		for (field = line; *field == ' ' || *field == '\t' || *field == '\r' || *field == '\v' || *field == '\f'; ++field);
		if (!*field) continue;
		for (k = 0, field = line; (field = strchr(field, '\t')); ++field) ++k;
		if (k == 0) fail("line %d is a sample name with no values", line_no);
		if (n_col < 0) n_col = k;
		else if (k != n_col)
			fail("line %d has %d values, and the samples before it have %d", line_no, k, n_col);
		if ((size_t)n >= n_cap) {
			if (n == INT_MAX || n_cap > SIZE_MAX / sizeof(char *) / 2) fail("too many samples");
			n_cap = n_cap ? n_cap * 2 : 256;
			names = xrealloc(names, n_cap * sizeof(char *));
		}
		if ((size_t)(n + 1) > SIZE_MAX / sizeof(double) / (size_t)n_col) fail("the table is too large");
		if ((size_t)(n + 1) * (size_t)n_col > x_cap) {
			size_t need = (size_t)(n + 1) * (size_t)n_col;
			x_cap = x_cap && x_cap <= SIZE_MAX / sizeof(double) / 2 ? x_cap * 2 : need;
			if (x_cap < need) x_cap = need;
			x = xrealloc(x, x_cap * sizeof(double));
		}
		tab = strchr(line, '\t');
		*tab = 0;
		names[n] = line;
		for (j = 0, field = tab + 1; j < n_col; ++j) {
			float v;
			tab = strchr(field, '\t');
			if (tab) *tab = 0;
			if (!is_number(field)) {
				char *c;
				for (c = field; *c; ++c)
					if ((unsigned char)*c < 32) *c = '?'; /* a control character, shown */
				fail("line %d, value %d is not a number: '%s'", line_no, j + 1, field);
			}
			/* main.c reads the values as floats */
			v = (float)strtod(field, NULL);
			if (!isfinite(v)) fail("line %d, value %d is too large: %s", line_no, j + 1, field);
			x[(size_t)n * n_col + j] = v;
			field = tab + 1;
		}
		++n;
	}
	if (n == 0) fail("%s holds no samples", path);

	{
		int varies = 0;
		for (j = 0; j < n_col && !varies; ++j)
			for (i = 1; i < n; ++i)
				if (x[(size_t)i * n_col + j] != x[j]) { varies = 1; break; }
		if (!varies) fail("all %d samples have the same values, so there is nothing to embed", n);
	}
	if (n - 1 < 3 * perplexity)
		fail("a perplexity (-p) of %g needs at least %.0f samples, and the table has %d; lower it to %g or less",
		     perplexity, ceil(3 * perplexity) + 1, n, floor((n - 1) / 3.0 * 1000) / 1000);

	/* bhtsne indexes with int, and wasm has a 32-bit size_t */
	{
		double cells = theta > 0 ? (double)n * (int)(3 * perplexity) * 2 : (double)n * n;
		double bytes = theta > 0 ? cells * (sizeof(double) + sizeof(unsigned)) * 2 : cells * sizeof(double) * 3;
		if ((double)n * n_col > INT_MAX || (double)n * out_dim > INT_MAX || cells > INT_MAX || bytes > (double)SIZE_MAX)
			fail(theta > 0 ? "%d samples at a perplexity (-p) of %g are too many for memory; lower the perplexity"
			               : "%d samples are too many for exact t-SNE (theta 0) in memory; set theta (-e) above 0",
			     n, perplexity);
	}

	y = ts_fit(n, n_col, x, out_dim, theta, perplexity, seed);
	for (i = 0; i < n; ++i) {
		size_t k = (size_t)i * out_dim;
		printf("%s", names[i]);
		for (j = 0; j < out_dim; ++j)
			printf("\t%g", y[k + j] + 1. - 1.);
		putchar('\n');
	}
	if (fflush(stdout) || ferror(stdout)) fail("cannot write the embedding");
	free(y);
	free(x);
	free(names);
	free(buf);
	return 0;
}
SHIM_EOF

# t-SNE calls the entry point's rand, srand, exp and log, the same in every
# runtime, and no step is fused into an FMA, which some CPUs have and wasm has
# not: so a seed gives the same embedding natively and in wasm.
cat > biochef_tsne.h <<'H_EOF'
#ifdef __cplusplus
extern "C" {
#endif
int biochef_rand(void);
void biochef_srand(unsigned int seed);
double biochef_exp(double x);
double biochef_log(double x);
#ifdef __cplusplus
}
#endif
H_EOF
sed -i -E 's/\b(rand|srand|exp|log)\(/biochef_\1(/g' tsne.cpp vptree.h
! grep -Eq '\b(rand|srand|exp|log)\(' tsne.cpp vptree.h sptree.cpp sptree.h t-sne.cpp
[ "$(cat tsne.cpp vptree.h | grep -o 'biochef_[a-z]*(' | wc -l)" -eq 14 ]
# The nearest neighbours of a sample come from a vantage-point tree, which
# orders samples at the same distance as the C++ library happens to: by
# libstdc++ natively and by libc++ in wasm. Samples at the same distance are
# ordered by their row instead, and the tree sorts where it partitioned, so
# that rows that repeat, or values that tie, give the same neighbours in both.
sed -i -e 's/^            return dist < o\.dist;$/            return dist < o.dist || (dist == o.dist \&\& index < o.index);/' \
  -e 's/^            return distance(item, a) < distance(item, b);$/            double da = distance(item, a), db = distance(item, b);\n            return da < db || (da == db \&\& a.index() < b.index());/' \
  -e 's|^    // Distance comparator for use in std::nth_element$|    // Distance comparator for use in std::sort|' \
  -e '/^            std::nth_element(_items.begin() + lower + 1,$/{s/std::nth_element(/std::sort(/;n;/^                             _items.begin() + median,$/d}' vptree.h
grep -q 'return dist < o.dist || (dist == o.dist && index < o.index);' vptree.h
grep -q 'return da < db || (da == db && a.index() < b.index());' vptree.h
grep -q '^            std::sort(_items.begin() + lower + 1,$' vptree.h
! grep -q 'nth_element' vptree.h
FLAGS="-Wall -O2 -ffp-contract=off"

emmake make sptree.o tsne.o t-sne.o CC=emcc CXX=em++ CFLAGS="$FLAGS" CPPFLAGS="-include biochef_tsne.h"
emcc $FLAGS -sUSE_ZLIB=1 -I. -c biochef_main.c -o biochef_main.o
em++ sptree.o tsne.o t-sne.o biochef_main.o -o bhtsne.js -lm -sUSE_ZLIB=1 $EM_FLAGS

mkdir -p out && mv bhtsne.js out/bhtsne.js && mv bhtsne.wasm out/bhtsne.wasm
