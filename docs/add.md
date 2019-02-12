# Description

Use this command to add named layers to the map from among those distributed with *nswtopo*. Refer to the website for a description of the various layers. Use the `nswtopo layers` command to display a list of available layers.

Layers are arranged hierarchically, with some layers being shorthand for a collection of other layers. For example, the `nsw/topographic` layer contains a large number of component layers, such as `nsw/topographic/roads`, `nsw/topographic/watercourses` etc.

The forward-slash character is used indicate the nested folder structure of these layers. However, once added to the map, these layers are renamed with periods (`nsw.topographic.watercourses`), and the use of period and slash characters is interchangeable.

# Options

Some layers, such as vegetation layers, require a dataset to be present on your computer. Specify the location of the dataset with the `--path` option. The path can be absolute, or relative to the working directory.

Raster layers (vegetation, shaded relief) typically have an appropriate image resolution set for that data. If desired, you can choose a different value using the `--resolution` option. Resolution is in metres per pixel, indicating the dataset quality rather than an output resolution such as pixels per inch.

For repeated use, it's easier to set the path or resolution for a layer in a permanent configuration file. Use the *config* command for this task.

# Positioning Layers

By default, layers are added to the map in an appropriate position for the type: vegetation and aerial layers first, followed by topographic feature layers, overlays, shaded relief, grid, declination and controls.

To instead select a specific position for the new layer, use the `--after` or `--before` option with an existing layer name. For example, to insert a KML overlay between existing topographic layers:

```
$ nswtopo add --after nsw.topographic.urban-areas map.tgz new-suburb.kml
```

# Other Layers

While *grid*, *declination*, overlay and *controls* layers each have a dedicated command, it's possible to add them directly if you don't need to change default settings:

```
$ nswtopo add map.tgz out-of-bounds.kml grid controls.gpx
```

Georeferenced rasters (e.g. GeoTIFFs) can also be added directly:

```
$ nswtopo add map.tgz underlay.tif
```

For advanced users, custom layer definitions can added by referencing the `.yml` definition file:

```
$ nswtopo add --after nsw.topographic.water-areas map.tgz bathymetry.yml
```

# Failed Layers

Map servers can sometimes be uncooperative, resulting in layers which fail to download. In this event, simply run the `add` command again to retry the failed layers. Existing layers will not be re-downloaded.
