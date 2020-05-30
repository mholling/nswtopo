# Description

Use the *inspect* command to examine ArcGIS REST endpoints and local GIS data.

# ArcGIS REST layers

List all the layers in an ArcGIS map or feature service as follows:

```
$ nswtopo inspect https://portal.spatial.nsw.gov.au/server/rest/services/NSW_Water_Theme/MapServer
layers:
├─ 0: HydroPoint
├─ 1: AncillaryHydroPoint
├─ 2: NamedWatercourse
├─ 3: FuzzyExtentWaterLine
├─ 4: Coastline
├─ 5: HydroLine
├─ 6: HydroArea
└─ 7: FuzzyExtentWaterArea
```

List the fields for a layer using the layer URL, or with the `--layer` or `--id` option. The layer's fields and their types will be listed:

```
$ nswtopo inspect https://portal.spatial.nsw.gov.au/server/rest/services/NSW_Water_Theme/MapServer/6
name: HydroArea
id: 6
geometry: Polygon
fields:
├─ attributereliabilitydate: Date
├─ capturemethodcode: SmallInteger
│  ...
├─ urbanity: String
└─ verticalaccuracy: Single
```

Use the `--fields` option to inspect values and counts for one or more fields:

```
$ nswtopo inspect --fields classsubtype,hydrotype https://portal.spatial.nsw.gov.au/server/rest/services/NSW_Water_Theme/MapServer/6
classsubtype │ 447690 │ 1
   hydrotype │   9070 │ ├─ 1
   hydrotype │ 438620 │ └─ 2
classsubtype │  20084 │ 2
   hydrotype │  19849 │ ├─ 1
   hydrotype │    235 │ └─ 2
```

Field names and all possible values are shown, with counts for each combination of values. In this case, the values are *coded values*. Use `--decode` to decode them:

```
$ nswtopo inspect --fields classsubtype,hydrotype --decode https://portal.spatial.nsw.gov.au/server/rest/services/NSW_Water_Theme/MapServer/6
classsubtype │ 447690 │ WaterbodyArea
   hydrotype │ 438620 │ ├─ ManMadeWaterBody
   hydrotype │   9070 │ └─ NaturalWaterBody
classsubtype │  20084 │ Watercourse
   hydrotype │    235 │ ├─ Canal-Drain
   hydrotype │  19849 │ └─ NaturalWatercourse
```

List all *coded value* conversions for a layer with the `--codes` option:

```
$ nswtopo inspect --codes https://portal.spatial.nsw.gov.au/server/rest/services/NSW_Water_Theme/MapServer/6
perenniality:
├─ 0 → NotApplicable
├─ 1 → Perennial
├─ 2 → NonPerennial
└─ 3 → MainlyDry
classsubtype:
├─ 1 → WaterbodyArea
│  └─ hydrotype:
│     ├─ 1 → NaturalWaterBody
│     └─ 2 → ManMadeWaterBody
└─ 2 → Watercourse
   └─ hydrotype:
      ├─ 1 → NaturalWatercourse
      └─ 2 → Canal-Drain
```

Use the `--where` option to restrict output using a SQL expression on the fields. (For some servers, this may not affect results.)

# Local GIS Data

Any OGR-readable data can likewise be examined using the `inspect` command. For example, to list layers contained in a spatialite file:

```
$ nswtopo inspect nsw.sqlite
layers:
├─ cableway (LineString)
├─ electricitytransissionline (LineString)
├─ railway (LineString)
└─ trafficcontroldevice (Point)
```

To list field values for a layer:

```
$ nswtopo inspect nsw.sqlite --layer cableway --fields classsubtype
classsubtype │  4 │ CableCar
classsubtype │ 19 │ FlyingFox
classsubtype │ 58 │ SkiLift
```
