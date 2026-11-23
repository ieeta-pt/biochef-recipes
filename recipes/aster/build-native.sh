set -eo pipefail

mkdir -p out

g++ -std=gnu++17 -O3 -pthread src/astral.cpp -o out/astral
g++ -std=gnu++17 -O3 -pthread src/astral-pro.cpp -o out/astral-pro
g++ -std=gnu++17 -O3 -pthread src/astral-hybrid.cpp -o out/wastral
g++ -std=gnu++17 -O3 -pthread src/caster-site.cpp -o out/caster-site
