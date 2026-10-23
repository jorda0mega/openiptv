#!/bin/zsh
# calibrate_mock.sh <real.json> [out-dir]: the baseline flow on the test server under real-quiet and then
# real-busy (mock_film_run.sh), each line side by side with the real server's (film_numbers.py compare),
# "!" where more than 20% off. real.json: the real runs' numbers, made from the runner's printed lines:
#   python3 scripts/film_numbers.py extract --as probe real-run.txt > real.json
# A line off is fixed in the test server (net_profiles.json, mock_server.py), never in the numbers.
set -u
real=$1 out=${2:-/tmp/openiptv/calibration}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p $out
rm -f $out/mock.json
echo '{}' > $out/mock.json
for profile in ${=PROFILES:-real-quiet real-busy}; do
  zsh $here/mock_film_run.sh $profile $out/mock-$profile.txt > /dev/null || { echo "$profile: the run failed"; exit 1; }
  python3 $here/film_numbers.py extract --as $profile --into $out/mock.json $out/mock-$profile.txt
done
python3 $here/film_numbers.py compare $real $out/mock.json | tee $out/table.txt
