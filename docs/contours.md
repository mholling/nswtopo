# Description

Generate contour lines directly from a Digital Elevation Model (DEM) with the *contours* command. Any DEM in a planar projection can be used, but high-resolution data is needed for good results.

# Obtaining the DEM
Use the *ELVIS* website [http://elevation.fsdf.org.au] to download DEM tiles for any NSW location. The NSW 2-metre and 5-metre tiles are ideal. 1-metre NSW and ACT tiles also work but are more detailed than necessary. (Do not download Geoscience Australia tiles or point-cloud data.)

DEM tiles from the ELVIS website are delivered as doubly-zipped files. It's not necessary to unzip the download, although unzipping the first level to a folder will improve processing time.

# Contour Configuration
Choose a contour interval in metres using the `--interval` option. A five metre interval is recommended as it conveys excellent detail and is not too dense for 1:25000 maps in most areas. Specify an index contour interval with the `--index` option.

Noise in raw elevation data usually produces unsuitably rough contour lines. Some smoothing of the DEM removes most such artefacts. A default smoothing radius of 0.2mm is applied, configurable with the `--smooth` option. Increase the radius to produce smoother contours at the expense of detail.

# Layer Position

Use an `--after`, `--before` or `--replace` option to insert the contours in an appropriate layer position. You will most likely want to replace an existing contour layer:

```
$ nswtopo contours --replace nsw.topographic.contours map.tgz DATA_25994.zip
```
# Style

Contours are rendered in brown at a thickness of 0.08mm. Change line colour with `--stroke`, thickness with `--stroke-width` and label colour with `--fill`. Colour can be an *RGB triplet* (e.g. *800080*) or *web colour* name (e.g. *purple*).

# Contour Thinning
A small contour interval can produce very dense contours in steep terrain. An advanced `--thin` option is available to selectively remove contours in steep areas such as cliffsides. It emulates a manual contour thinning technique. An index multiple of eight (e.g. 5m contours with 40m index contours) produces the most aesthetic results.

(*GDAL* with *SpatiaLite* and *GEOS* support is required to perform contour thinning.)

# Knolls & Depressions

Contours generated from a DEM can include depression artefacts, most noticeabley at pinch-points in flat or closed-in watercourses. These do not usually represent true depression contours, which are rare. Any isolated depression contours are automatically detected and removed. All nested depression contours are retained and rendered as true depression contours. This behaviour can be disabled with the `--no-depression` option.

Contours for tiny knolls are also removed. Use the `--knolls` option to specify the minimum size for knolls to be retained.

When creating contours from a DEM, it's recommended to also generate a new spot heights layer. Use the *spot-heights* command to generate them using the same DEM.
