# d4-plot

Interactive D4 coverage viewer built with [UIng](https://github.com/kojix2/uing). Open a D4 file, choose a chromosome or enter a 1-based inclusive region, and render its mean coverage in a configurable number of bins. Click to zoom in, right-click to zoom out, drag to pan, or click the chromosome overview to jump.

```sh
cd examples/d4-plot
shards install
shards build --release
bin/d4-plot
```

The viewer streams narrow regions and uses an embedded sum index for wide regions when one is available. The setting can disable index use. Annotation files can be opened from the toolbar.
