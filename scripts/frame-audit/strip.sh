#!/bin/zsh
# strip.sh video.mp4 first_frame count out.png: consecutive 30 fps frames (as scan.py counts them) side by side.
ffmpeg -v error -y -i $1 -vf "fps=30,select='between(n\,$2\,$(($2+$3-1)))',scale=300:-2,tile=${3}x1:padding=6:color=red" -frames:v 1 $4
