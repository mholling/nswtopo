ACT Map Layers
==============

This directory contains map layers specific to the Australian Capital Territory.

## 2012, 2015 & 2017 Aerial Imagery

A territory-wide, high-resolution aerial imagery layer is available from an ACT government server. The default resolution is 2.0 metres per pixel and can be changed with the `--resolution` option. Names for the layers are `act/aerial-2012`, `act/aerial-2015` and `act/aerial-2017`.

## Contours

This layer shows high-resolution 5-metre contours generated from 2015 ACT LiDAR data. The contours are unprocessed, contain some noise and are slow to label. For a better result, download DEM tiles manually and use the [`nswtopo contours`](../../docs/contours.md) command.

Add the layer in place of the `nsw/topographic/contours` layer as follows:

```sh
$ nswtopo add --replace nsw.topographic.contours map.tgz act/contours
```

## Relief

`act/relief` is a matching shaded-relief layer for the 5m ACT contours. Again, it can be slow to download and compute.

## Water Areas

`act/water-areas` is an alternate waterbody layer for the ACT. It can replace the `nsw/topographic/water-areas` layer.
