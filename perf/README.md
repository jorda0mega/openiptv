# Playback evals

Every playback change is measured against `best.json`: the best recorded run of each metric, per target and platform, with the commit and date that set it. Anything slower is a regression unless the user agrees it buys something.

Metric names live in `apple/OpenIPTV/Telemetry/`: `Metric.Name` (also sent from TestFlight builds) and `Metric.EvalName` (Debug builds only, measured only here). Nothing in this folder adds anything visible to the app.

## Run it

Commit first: each run builds the last commit, not the working tree.

```
zsh perf/eval.sh mock          # the test server under the worst profile
zsh perf/eval.sh mock real-busy
```

The mock run takes about 1.5 hours on the iPhone, Apple TV and iPad simulators, one at a time. It covers starts, ±10 s and 5 minute jumps, subtitle look (an SDR 720p and an HDR10 film), live start and switches, and Picture in Picture's gaps. It ends with a table against `best.json`: better, same or REGRESSION, judged by the run's own spread and the spread between earlier runs. `ONLY="starts jumps"` and `PLATFORMS="ios"` pick parts.

The real run (starts and jumps, iPhone then Apple TV) is started by the developer only, with the logins helper running:

```
FEED=http://127.0.0.1:8799 zsh perf/eval.sh real
```

The logins stay in the helper. The app reports nothing to the server, and the output carries no address (it ends with its url-like count, which must be 0).

After a run, `python3 -I perf/perf.py best` folds its runs into `best.json`.

## Pieces

- `sim_runs.sh` runs one timing test at a list of commits, holding each lock only for its step.
- `jumps.py` times each jump to the new picture from the app's log and a screen recording of `make_jump_film.sh`'s film, whose frames carry their own numbers. It also reports how far ahead libmpv had downloaded.
- `starts.py` splits each start into the plan, the file's first reads and the first frame, with the server's own timings.
- `subtitle_look.py` reads subtitle size, sharpness and brightness from screenshots and the Debug frame readout.
- `frame_probe.sh` draws one frame with the app's libmpv on the Mac, with no simulator.
