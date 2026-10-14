"""control.py video.mp4: the scanner must find a planted jump, flash and
blank in a still page taken from a recording (frame 705)."""
import sys
import numpy as np
from scan import frames, analyze

still = frames(sys.argv[1])[705]
H = still.shape[0]
seq = [still] * 10
moved = still.copy(); moved[int(H * .45):-20] = still[int(H * .45) + 20:]   # jump: lower half 20 px (~40 pt) up
seq += [moved] * 10
flash = moved.copy(); flash[int(H * .3):int(H * .6)] = 255                  # flash: one white frame over the list
seq += [flash] + [moved] * 10
blank = moved.copy(); blank[int(H * .2):int(H * .9)] = 0                    # blank: 5 frames of an empty list
seq += [blank] * 5 + [moved] * 10 + [still] * 3
events, _ = analyze(np.stack(seq))
for e in events: print(e)
kinds = {e["kind"] for e in events}
sys.exit(0 if {"move", "flash", "blank"} <= kinds else 1)
