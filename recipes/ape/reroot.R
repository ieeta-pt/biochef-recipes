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

if (!outgroup %in% tree$tip.label) {
  stop("outgroup '", outgroup, "' is not a tip in this tree")
}

write.tree(root(tree, outgroup = outgroup, resolve.root = TRUE), file = arg("--out"))
cat("rerooted on", outgroup, "\n")
