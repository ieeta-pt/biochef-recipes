# Summarises a phylogenetic tree.
#
#   summary.R --tree <file> --out <file>
#
# Arguments are named rather than positional. BioChef builds the argument
# vector as parameters first, then inputs, then outputs, so position is not
# something a script can rely on.
#
# The argv idiom lets the same script run under Rscript, so an operation can be
# exercised outside the browser.
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

# A topology-only tree -- "((A,B),(C,D));" -- is valid Newick, and the input is
# typed TEXT so nothing upstream rejects it. The four branch-length rows are
# then undefined: is.ultrametric() errors outright, while sum() and
# node.depth.edgelength() quietly return zero, which would be reported as fact.
# Report NA for those rows instead and still emit the topology ones.
# As in distances.R: a partially annotated tree keeps an edge.length vector
# containing NA, which is.null() does not catch and which makes is.ultrametric()
# fail with "NA/NaN/Inf in foreign function call".
has_lengths <- !is.null(tree$edge.length) && !anyNA(tree$edge.length)

writeLines(c(
  paste("tips", Ntip(tree), sep = "\t"),
  paste("internal_nodes", Nnode(tree), sep = "\t"),
  paste("rooted", is.rooted(tree), sep = "\t"),
  paste("binary", is.binary(tree), sep = "\t"),
  paste("ultrametric", if (has_lengths) is.ultrametric(tree) else NA, sep = "\t"),
  paste("total_branch_length", if (has_lengths) sum(tree$edge.length) else NA, sep = "\t"),
  paste("max_root_to_tip", if (has_lengths) max(node.depth.edgelength(tree)) else NA, sep = "\t")
), arg("--out"))

cat("summarised a tree with", Ntip(tree), "tips\n")
