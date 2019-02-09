# Description

Use the *overlay* command to overlay GPX and KML files on the map. You can add both tracks (paths) and areas (polygons). Tracks can be added from GPX files, typically recorded by a GPS device. Create KML files by using *Google Earth* to trace out paths and polygons in various colours and styles.

# Adding Styles

The simplest way to add styles your overlay is with Google Earth. When drawing paths and polygons, set their colours and line-widths in the `Style, Color` tab. (Google Earth line-widths are in pixels, about 0.25mm each.) These styles will be honoured when you subsequently add the KML file to your map.

You can also use options to change styles for overlay features:

* **opacity**: layer opacity
* **stroke**: line colour
* **stroke-width**: line thickness in millimetres
* **stroke-dasharray**: list of measurements representing a dash pattern
* **stroke-opacity**: opacity of line strokes
* **fill**: fill colour
* **fill-opacity**: opacity of fill colour

These options will override styles set in a KML file. There are also useful for GPX files, which do not include style information. Opacities are given as a value between 0 and 1. Colours can be either an *RGB triplet* (e.g. *#800080*), *web colour* name (e.g. *purple*) or *none*.

The `--stroke-dasharray` option is useful for display a track as a dashed line. For example, to add unmarked firetrails to a map in dashed orange:

```
$ nswtopo overlay --stroke "#FF7518" --stroke-width 0.3 --stroke-dasharray 1.8,0.6 -s map.tgz tracks.gpx
```

Layer- and fill-opacity is best used to mark translucent polygons on the map. For example, to render out-of-bounds areas on a map as translucent black:

```
$ nswtopo overlay --stroke none --fill black --opacity 0.3 map.tgz oob.kml
```

# Track Simplification

When importing GPS tracks, noise can produce unwanted irregularities or roughness. Some simplification is applied to GPX tracks to smooth out these artefacts and produce a better-looking track. Use the `--simplify` option to apply simplification to KML linestrings as well.

The default tolerance ensures that the track position will not be adjusted by more than 0.5 millimetres on the map. Tolerance can be adjusted by providing a `--tolerance` value.
