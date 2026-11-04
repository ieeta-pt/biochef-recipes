mkdir -p out

em++ -std=c++17 -O3 src/astral.cpp -o out/astral.js $EM_FLAGS
em++ -std=c++17 -O3 src/astral-pro.cpp -o out/astral-pro.js $EM_FLAGS
em++ -std=c++17 -O3 src/astral-hybrid.cpp -o out/wastral.js $EM_FLAGS
em++ -std=c++17 -O3 src/caster-site.cpp -o out/caster-site.js $EM_FLAGS
