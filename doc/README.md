# Description

Use *nswtopo* to create vector topographic maps of NSW and other states. Various *commands* allow you to initialise your map, add layers and render outputs in a number of formats. Pre-designed map layers download topographic data from internet maps servers and local sources.

# Commands

Help screens are available describing usage for each commands. Use the `--help` option with the command:

```
$ nswtopo init --help
```

# Configuration

An important initial step is to configure the location of *Google Chrome* on your PC. Chrome is required for rendering the map in most formats. Use the *configure* command to set the path:

```
$ nswtopo config --chrome "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
nswtopo: configuration updated
```

Use forward slashes for paths, even on Windows.

# Map Files

Most commands need a map file to work on. Name this file anything you want. A `.tgz` extension is suggested, as the file is in *gzipped tar* archive format. All map contents are contained within the file, so a separate directory per map is not necessary.

# Example

A typical map creation sequence might look as follows. We initialise the map from a bounds file, add several layers and finally produce an output SVG:

```
$ nswtopo init -b bounds.kml map.tgz
scale:      1:25000
dimensions: 433mm × 509mm
extent:     10.8km × 12.7km
area:       138.0km²
rotation:   0.0°
```

```
$ nswtopo add map.tgz nsw/vegetation-spot5
nswtopo: added layer: nsw.vegetation-spot5
```

```
$ nswtopo add map.tgz nsw/topographic
nswtopo: added layer: nsw.topographic.plantation-horticulture
nswtopo: added layer: nsw.topographic.urban-areas
...
nswtopo: added layer: nsw.topographic.spot-heights
```

```
$ nswtopo declination map.tgz
nswtopo: added layer: declination
```

```
$ nswtopo add map.tgz controls.gpx
nswtopo: added layer: controls
```

```
$ nswtopo relief map.tgz DATA_25994.zip
nswtopo: added layer: relief
```

```
$ nswtopo contours -i 5 -x 50 --replace nsw.topographic.contours map.tgz DATA_25994.zip
nswtopo: added layer: contours
```

```
$ nswtopo render map.tgz svg
nswtopo: created map.svg
```

