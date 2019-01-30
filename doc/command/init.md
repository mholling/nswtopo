# Description

Use the *init* command to initialise a new map file. Options for the command allow you to specify the size, location and orientation of the map. This metadata will be stored in the map file, along with map data for the various layers you subsequently add.

By convention, use a `.tgz` file extension for your map file, since it's in a *gzipped tar* archive format.

# Setting Map Location

The easiest way to set bounds is with the `--bounds` option. Using Google Earth, draw out a polygon covering the area for your map, save as a KML file, then run the command:

```
nswtopo init --bounds bounds.kml map.tgz
```

This will create a map file covering the specified area. You can also use map corner waypoints for your bounds, or a GPX file of a recorded track. An additional margin can be set with the `--margin` option. (If waypoints or tracks are used to specify the bounds, a 15mm margin will be applied by default.)

An alternative way to set the map bounds is to specify two or more GPS coordinates using the `--coords` option. Provide a list of longitude & latitude coordinate pairs (e.g. for opposing corners of the map).

# Map Orientation and Size

Maps are north-oriented unless otherwise requested. The `--rotation` option will produce a map with a given rotation angle. Use the `magnetic` keyword to align the map with magnetic north. The keyword `auto` yields a map oriented so as to fit your bounds in the smallest possible area.

You can make a map with set dimensions by using the `--dimensions` option, providing a width and height for the map in millimetres. For example, creating an A4 map at a given location:

```
nswtopo init --width 210,297 --coords 148.387,-36.148 map.tgz
```

# Map Scale

A 1:25000 scale is conventional and should work well for most applications. Change to a smaller or larger scale using the `--scale` option.
