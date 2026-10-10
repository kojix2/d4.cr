# d4-plot

A small graphical D4 viewer implemented with pure-Crystal d4.cr and UIng.
It does not require the Rust d4binding library. The UI requires libui, GTK 3
development libraries on Linux, and a working graphical display. `make build`
installs the UIng shard when it is missing.

```sh
make build
./bin/d4-plot
```

Open a D4 file with the button or File menu. Enter a 1-based inclusive genomic
region such as `chr1:1000-2000`, select the number of bins, then render. Each
bin is plotted at its midpoint with its mean value. Narrow bins are computed
in one stream; wide bins use an embedded sum index when present. Large regions
can take time without an index; no index is required to run.

