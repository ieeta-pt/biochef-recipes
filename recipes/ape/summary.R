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

depths <- node.depth.edgelength(tree)

writeLines(c(
  paste("tips", Ntip(tree), sep = "\t"),
  paste("internal_nodes", Nnode(tree), sep = "\t"),
  paste("rooted", is.rooted(tree), sep = "\t"),
  paste("ultrametric", is.ultrametric(tree), sep = "\t"),
  paste("binary", is.binary(tree), sep = "\t"),
  paste("total_branch_length", sum(tree$edge.length), sep = "\t"),
  paste("max_root_to_tip", max(depths), sep = "\t")
), arg("--out"))

cat("summarised a tree with", Ntip(tree), "tips\n")
