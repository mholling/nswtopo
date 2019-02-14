# Description

Use the *spot-heights* command to generate spot heights directly from a Digital Elevation Model (DEM). This command is best used in conjunction with contours generated from the same DEM.

# Obtaining the DEM
Use the *ELVIS* website [http://elevation.fsdf.org.au] to download DEM tiles for any NSW location. The NSW 2-metre and 5-metre tiles are ideal. 1-metre NSW and ACT tiles also work but are more detailed than necessary. (Do not download Geoscience Australia tiles or point-cloud data.)

DEM tiles from the ELVIS website are delivered as doubly-zipped files. It's not necessary to unzip the download, although unzipping the first level to a folder will improve processing time.

# Spot Height Configuration
Use the `--spacing` option to determine the maximum density of spot heights on the map. The value in millimetres represents the minimum distance between any two spot heights.

Choose the amount of smoothing to apply to the DEM with the `--smooth` option. The value represents a smoothing radius in millimetres. For consistency, the same smoothing radius shoult be used for both contours and spot heights.

Use the `--prefer` option to favour `knolls` or `saddles` when selecting spot locations. No preference is taken by default.

# Layer Position

Use an `--after`, `--before` or `--replace` option to insert the spot heights in an appropriate layer position. You will most likely want to replace an existing spot heights layer:

```
$ nswtopo spot-heights --replace nsw.topographic.spot-heights map.tgz DATA_25994.zip
```
