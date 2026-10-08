# Reroots a phylogenetic tree on an outgroup.
#
#   reroot.R --tree <file> --out <file> --outgroup <tip label>
#
# Arguments are named rather than positional. BioChef builds the argument
# vector as parameters first, then inputs, then outputs, so position is not
# something a script can rely on.
#
# Only outgroup rooting is offered. Midpoint rooting is not in ape -- it lives
# in phangorn -- and pulling in a second package for it is not worth it here.
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

outgroup <- arg("--outgroup")
tree <- read.tree(arg("--tree"))
if (is.null(tree)) stop("could not read a tree from the input")
if (inherits(tree, "multiPhylo")) {
  stop("the input holds ", length(tree), " trees; this operation takes exactly one")
}

if (!outgroup %in% tree$tip.label) {
  stop("outgroup '", outgroup, "' is not a tip in this tree")
}

# Newick permits a length on some edges and not others, and ape then fills the
# rest with NA. root() carries those NAs into the arithmetic that splits the new
# root edge and writes NaN, which is not in the Newick grammar, while reporting
# success -- so the damage is only noticed by whatever consumes the tree next,
# which then blames its own input. summary.R and distances.R guard the same case.
if (!is.null(tree$edge.length) && anyNA(tree$edge.length)) {
  stop("this tree has branch lengths on only some edges, so rerooting would ",
       "produce undefined lengths")
}

write.tree(root(tree, outgroup = outgroup, resolve.root = TRUE), file = arg("--out"))
cat("rerooted on", outgroup, "\n")
