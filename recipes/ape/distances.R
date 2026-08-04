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

d <- cophenetic.phylo(tree)
if ("--upper-only" %in% argv) d[lower.tri(d)] <- NA

# Built in memory and written once. A connection held open across the loop
# would need on.exit() to close reliably, and on.exit() has no function frame
# to attach to at the top level of a sourced script.
rows <- paste(c("", colnames(d)), collapse = "\t")
for (r in rownames(d)) {
  values <- ifelse(is.na(d[r, ]), "", format(d[r, ], trim = TRUE))
  rows <- c(rows, paste(c(r, values), collapse = "\t"))
}
writeLines(rows, arg("--out"))

cat("wrote a", nrow(d), "by", ncol(d), "distance matrix\n")
