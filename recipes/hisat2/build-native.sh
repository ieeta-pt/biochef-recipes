set -eo pipefail

for tool in align build inspect; do
  make "hisat2-$tool-s" \
    EXTRA_FLAGS="-DPOPCNT_CAPABILITY -std=c++11 -Dmain=hisat2_tool_main -DBC_${tool^^} biochef_main.cpp" \
    NO_TBB=1
done
