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
cell <- function(x) {
  if (is.na(x)) "" else format(x, trim = TRUE, scientific = FALSE, digits = 15)
}

rows <- paste(c("", colnames(d)), collapse = "\t")
for (i in seq_len(nrow(d))) {
  values <- vapply(d[i, ], cell, character(1))
  rows <- c(rows, paste(c(rownames(d)[i], values), collapse = "\t"))
}
writeLines(rows, arg("--out"))

cat("wrote a", nrow(d), "by", ncol(d), "distance matrix\n")
