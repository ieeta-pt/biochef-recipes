set -eo pipefail

# The sources muscle.vcxproj lists and the options vcxproj_make.py gives
# them (src/build_linux.bash), without -march=native, so the binary runs on
# any x86_64. gitver.txt as vcxproj_make.py writes it.
cd src
echo "\"$(git log --oneline | head -n1 | cut -d' ' -f1)\"" > gitver.txt
sed -n 's/.*<ClCompile Include="\([^"]*\)".*/\1/p' muscle.vcxproj > sources.txt
mkdir -p obj
xargs -P 4 -I{} sh -c 'g++ -O3 -DNDEBUG -ffast-math -fopenmp -c {} -o obj/$(basename {} .cpp).o' < sources.txt
mkdir -p ../bin
g++ -O3 -ffast-math -fopenmp -static obj/*.o -o ../bin/muscle
