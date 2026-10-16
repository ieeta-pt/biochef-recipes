sed -i.bak "s|asm_opt->bf_shift = 37;|asm_opt->bf_shift = 0;|" CommandLines.cpp

make -j4
