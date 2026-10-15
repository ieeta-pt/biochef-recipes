# Writes the patristic distance matrix of a tree as a TSV.
#
#   distances.R --tree <file> --out <file> [--upper-only]
#
# Arguments are named rather than positional. BioChef builds the argument
# vector as parameters first, then inputs, then outputs, so position is not
# something a script can rely on.
argv <- if (exists("argv")) argv else commandArgs(trailingOnly = TRUE)

arg <- function(name, required = TRUE) {
  i <- match(name, argv)
  if (is.na(i)) {
    if (required) stop(name, " is required")
    return(NULL)
  }
  if (i == length(argv)) stop(name, " needs a value")
  argv[i + 1]
}

suppressPackageStartupMessages(library(ape))

tree <- read.tree(arg("--tree"))
if (is.null(tree)) stop("could not read a tree from the input")
if (inherits(tree, "multiPhylo")) {
  stop("the input holds ", length(tree), " trees; this operation takes exactly one")
}

# Without branch lengths cophenetic.phylo() silently counts nodes instead of
# summing lengths and returns that as a distance matrix. summary.R reports NA
# for the same tree; the two operations should not disagree about whether the
# input can be answered.
# Newick permits a length on some edges and not others, in which case ape fills
# the rest with NA rather than dropping the vector, so is.null() alone does not
# catch it and the undefined cells would be written as empty strings --
# indistinguishable from the blanks --upper-only produces.
if (is.null(tree$edge.length) || anyNA(tree$edge.length)) {
  stop("this tree is missing branch lengths, so patristic distances are undefined")
}

d <- cophenetic.phylo(tree)
if ("--upper-only" %in% argv) d[lower.tri(d)] <- NA

# Rows are taken by position, not by name. Tip labels need not be unique, and
# d["A", ] returns the FIRST row matching "A", so a duplicated label would emit
# one tip's distances twice and never write the other's -- silently, and giving
# a matrix that is not even symmetric.
#
# Each value is formatted on its own with scientific notation disabled.
# format() applied to a whole row picks one common representation per row, so
# the same distance could appear as 2.500004e+05 in one row and 250000.4 in
# another, and its default of 7 significant digits silently truncates.
#
# Built in memory and written once. A connection held open across the loop
# would need on.exit() to close reliably, and on.exit() has no function frame
# to attach to at the top level of a sourced script.
# A tip label may legally contain a tab, and Newick quoting keeps it in the
# label, which would shift that row's columns and give a file whose rows are
# not all the same width. Separators are replaced rather than the label
# rejected, since the label is the user's data.
safe_label <- function(x) gsub("[\t\r\n]", " ", x)

# Formatted in a single call over the whole matrix. Doing it per value is
# around two hundred times slower and dominates the operation at a few hundred
# tips -- cophenetic.phylo itself takes milliseconds -- and nothing on this path
# has a timeout or, over webR's PostMessage channel, an interrupt. Doing it per
# row is what the per-value version was written to avoid: format() picks one
# representation per call, so the same distance could appear two ways in one
# file. One call over everything is fast and gives every cell the same
# representation. sprintf("%.15g") is not an alternative: it emits scientific
# notation below 1e-4.
cells <- format(d, trim = TRUE, scientific = FALSE, digits = 15)
cells[is.na(d)] <- ""

labels <- safe_label(rownames(d))
rows <- paste(c("", safe_label(colnames(d))), collapse = "\t")
for (i in seq_len(nrow(d))) {
  rows <- c(rows, paste(c(labels[i], cells[i, ]), collapse = "\t"))
}
writeLines(rows, arg("--out"))

cat("wrote a", nrow(d), "by", ncol(d), "distance matrix\n")
