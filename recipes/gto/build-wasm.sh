cd src

make clean

emmake make CC="emcc -msimd128 $EM_FLAGS"

for file in ../bin/*; do
  if [[ -f "$file" && "$(basename "$file")" != *.* ]]; then
    mv "$file" "${file}.js"
  fi
done