set -eo pipefail

for tool in class build inspect; do
  case $tool in
    class) bin=centrifuge-class ;;
    *) bin=centrifuge-$tool-bin ;;
  esac
  make "$bin" \
    EXTRA_FLAGS="-DPOPCNT_CAPABILITY -Dmain=centrifuge_tool_main -DBC_${tool^^} biochef_main.cpp" \
    NO_TBB=1
done
