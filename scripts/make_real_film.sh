#!/bin/zsh
# make_real_film.sh [out-dir]: a test film laid out like a real one on Emby (about 900 MB): eight minutes of 720p
# at 14 Mbit/s (8 MB is 4-5 s of it), keyframes 2 s apart, 5.1 and stereo sound, English and Spanish subtitles
# with a line over most seconds, its index (Cues) at the end, and its tags after the index, where mkvmerge writes
# them. Continue Watching resumes it 5 minutes in:
#   OPENIPTV_MOCK_VIDEO=<out>/real.mkv OPENIPTV_MOCK_RUNTIME=480 and /mock/set?resume_movies=1,2
set -e
out=${1:-/tmp/openreel-media/real}
mkdir -p $out
ffmpeg -v error -y -f lavfi -i "testsrc2=size=1280x720:rate=24,noise=alls=24:allf=t+u" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 60 -map 0:v -map 1:a -map 1:a \
  -c:v libx264 -preset ultrafast -b:v 14M -maxrate 16M -bufsize 16M -g 48 -keyint_min 48 -sc_threshold 0 -pix_fmt yuv420p \
  -c:a:0 ac3 -b:a:0 640k -ac:a:0 6 -c:a:1 aac -b:a:1 128k -ac:a:1 2 $out/minute.mkv
for i in {1..8}; do echo "file '$out/minute.mkv'"; done > $out/parts.txt
for lang in eng spa; do
  for k in {0..119}; do
    printf '%d\n00:%02d:%02d,100 --> 00:%02d:%02d,700\n%s %d\n\n' $((k + 1)) $(((3 + 4 * k) / 60)) $(((3 + 4 * k) % 60)) \
      $(((5 + 4 * k) / 60)) $(((5 + 4 * k) % 60)) $lang $k
  done > $out/$lang.srt
done
ffmpeg -v error -y -f concat -safe 0 -i $out/parts.txt -i $out/eng.srt -i $out/spa.srt -map 0 -map 1 -map 2 -c copy -c:s srt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=spa -metadata:s:s:0 language=eng -metadata:s:s:1 language=spa $out/real.mkv
rm $out/minute.mkv $out/parts.txt
python3 -I - $out/real.mkv <<'EOF'
import os, sys

def vint(d, i, keep):
    n = 1
    while not d[i] & (0x80 >> (n - 1)):
        n += 1
    v = d[i] if keep else d[i] & ((0x80 >> (n - 1)) - 1)
    for b in d[i + 1:i + n]:
        v = v << 8 | b
    return v, n

def element(eid, body, wide=False):
    size = (0x01 << 56 | len(body)).to_bytes(8, "big") if wide or len(body) > 126 else bytes([0x80 | len(body)])
    return eid.to_bytes((eid.bit_length() + 7) // 8, "big") + size + body

path = sys.argv[1]
with open(path, "r+b") as f:
    d = f.read(1 << 20)
    _, a = vint(d, 0, True); size, b = vint(d, a, False)
    segment = a + b + size
    _, a = vint(d, segment, True)
    data = segment + a + 8
    i, found = data, {}
    while True:
        eid, a = vint(d, i, True); length, b = vint(d, i + a, False)
        if eid == 0x1F43B675:
            break
        found[eid] = (i, a + b + length, i + a + b)
        i += a + b + length
    tags_at, tags_size, _ = found[0x1254C367]
    tags = d[tags_at:tags_at + tags_size]
    end = os.path.getsize(path)
    seeks, (head_at, head_size, j) = [], found[0x114D9B74]
    while j < head_at + head_size:
        eid, a = vint(d, j, True); length, b = vint(d, j + a, False)
        if eid == 0x4DBB:
            k, target, position = j + a + b, None, None
            while k < j + a + b + length:
                cid, ca = vint(d, k, True); clen, cb = vint(d, k + ca, False)
                value = int.from_bytes(d[k + ca + cb:k + ca + cb + clen], "big")
                target, position = (value, position) if cid == 0x53AB else (target, value) if cid == 0x53AC else (target, position)
                k += ca + cb + clen
            seeks.append((target, end - data if target == 0x1254C367 else position))
        j += a + b + length
    void_at, void_size, _ = found[0xEC]
    head = element(0x114D9B74, b"".join(element(0x4DBB, element(0x53AB, t.to_bytes(4, "big")) + element(0x53AC, p.to_bytes((p.bit_length() + 7) // 8 or 1, "big")))
                                        for t, p in seeks))
    room = head_size + void_size
    assert void_at == head_at + head_size and len(head) + 9 <= room
    f.seek(head_at); f.write(head + element(0xEC, bytes(room - len(head) - 9), wide=True))
    f.seek(tags_at); f.write(element(0xEC, bytes(tags_size - 9), wide=True))
    f.seek(end); f.write(tags)
    _, a = vint(d, segment, True)
    f.seek(segment + a); f.write((0x01 << 56 | end + len(tags) - data).to_bytes(8, "big"))
EOF
rm $out/eng.srt $out/spa.srt
echo $out/real.mkv
