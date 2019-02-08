# NSW Map Layers

This directory contains map layers specific to New South Wales. For a NSW topographic map, you will want to include `nsw/topographic` and probably also one of the vegetation layers.

## Adding the Layers

Each of the described layers can be added to your map like so:

```sh
$ nswtopo add map.tgz nsw/vegetation-spot5
$ nswtopo add map.tgz nsw/topographic
$ nswtopo add map.tgz nsw/relief
```

## Topographic

The `nsw/topographic` layers are derived from the NSW [*Digital Topographic Database*](http://www.lpi.nsw.gov.au/mapping_and_imagery/topographic_data) (DTDB), which contains the current topographic features for the entire state. It produces a nicely styled map with most of the features you'd expect from the printed NSW topographic map sheets.

Undesired layers can be removed as follows:

```sh
nswtopo remove map.tgz nsw.topographic.reserves
```

## Relief

Generates a shaded relief overlay derived from contours used in the `nsw/topographic` layer.

## Aerial Imagery

A high-resolution aerial imagery layer, `nsw/aerial`, is also available from the NSW LPI department. This layer is a mosaic of the best NSW LPI imagery at a default of 1.0 metres. A lot of the imagery has a native resolution of 0.5 m/px, and can yield very a very detailed image. However, for a map of reasonable size, the image produced at this resolution can be extremely large. Specify a different resolution as follows:

```sh
$ nswtopo add --resolution 2.0 map.tgz nsw/aerial
```

## Reference Topo Maps

These layers (`nsw/reference-topo-current` and `nsw/reference-topo-s1`) contain lower-resolution topographic map raster images at various points in time (recent and older, respectively). They are useful to have as a reference for comparison against the output of this software.

## SPOT5 Vegetation

Use the *SPOT5 woody extent and foliage projective cover (FPC) (5-10m) 2011* dataset for a high-resolution woody vegetation underlay. This data is at 5-metre resolution, and classifies woody areas by their foliage projective cover (the fraction of green foliage). The dataset is [described here](http://www.auscover.org.au/xwiki/bin/view/Product+pages/nsw+5m+woody+extent+and+fpc), with a direct FTP download currently at <ftp://qld.auscover.org.au/spot/woody_fpc_extent/nsw-2011/s5hgps_nsw_y20082012_bcvl0.tif>. It's a large 8.6Gb download, but worth it if you wish to make many maps. The same FTP server also has individual tiles available at more reasonable sizes (choose the `bcvm` file), but you'll need to determine which tile contains your map area.

Configure *nswtopo* with the path to the data as follows:

```sh
$ nswtopo config --path /Users/matthew/SPOT5/s5hgps_nsw_y20082012_bcvl0.tif nsw.vegetation-spot5
```
