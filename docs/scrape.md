# Description

Use *scrape* to download data from ArcGIS REST endpoint. Data may be downloaded from both *FeatureServer* and *MapServer* services, including *MapServer* services with no *Query* capability.

# Usage

Download some layers from an NSW ArcGIS server to a sqlite database `nsw.sqlite`:

```
$ nswtopo scrape https://portal.spatial.nsw.gov.au/server/rest/services/NSW_Transport_Theme/MapServer/1 nsw.sqlite
nswtopo: saved 87731 features
$ nswtopo scrape https://portal.spatial.nsw.gov.au/server/rest/services/NSW_Features_of_Interest_Category/MapServer/6 nsw.sqlite
nswtopo: saved 6569 features
$ nswtopo scrape https://portal.spatial.nsw.gov.au/server/rest/services/NSW_Transport_Theme/MapServer/10 nsw.sqlite
nswtopo: saved 81 features
```

Provide the full URL for the layer, including id number, or use the `--id` or `--layer` option along with the service URL:

```
$ nswtopo scrape --layer Railway https://portal.spatial.nsw.gov.au/server/rest/services/NSW_Transport_Theme/MapServer nsw.sqlite
nswtopo: saved 12979 features
```

Shapefile and sqlite output formats are supported. The filename extension determines the format, with `.sqlite` or `.db` selecting sqlite output, `.shp` a single shapefile layer, and any other filename a shapefile directory.

Downloaded layers are named according to the ArcGIS layer name, or from the `--layer` option if specified.

# Filtering

Use the `--coords` option to restrict feature download to a specified bounding box:

```
$ nswtopo scrape --coords 148.26,-36.52,148.38,-36.47 https://portal.spatial.nsw.gov.au/server/rest/services/NSW_Transport_Theme/MapServer/10 nsw.sqlite
nswtopo: saved 12 features
```

Use the `--where` option to restrict the download to certain field values:

```
$ nswtopo scrape --where "classsubtype = 1" https://portal.spatial.nsw.gov.au/server/rest/services/NSW_Transport_Theme/MapServer/10 nsw.sqlite
nswtopo: saved 58 features
```

# Fields

If all fields are not needed, apply the `--fields` option to specify a list of fields to be downloaded:

```
$ nswtopo scrape --fields CONTOUR_TY,ELEVATION https://services.thelist.tas.gov.au/arcgis/rest/services/Public/OpenDataWFS/MapServer/16 tas.sqlite
nswtopo: saved 528438 features
```

Some ArcGIS fields contain `coded values`—integers or short strings representing longer, more descriptive strings. These can be decoded during download using the `--decode` option:

```
$ nswtopo scrape --fields classsubtype,hydrotype --decode https://portal.spatial.nsw.gov.au/server/rest/services/NSW_Water_Theme/MapServer/6 nsw.sqlite
nswtopo: saved 467774 features
```

The `--decode` flag is particularly useful with type and subtype fields, where the same subtype code has a different meaning depending on the type code. Use the *inspect* command to view all codings for a given layer.

# Scraping from Map Layers

Some ArcGIS REST map layers do not allow feature queries. It is still possible to download features from such a layer, provided it supports SVG output and dynamic layers.

When this situation occurs, you will be prompted to provide a *unique value* field name with the `--unique` option. Choose a layer field which is likely to have a small number of possible values. An integer field such as a type or subtype field is a good candidate.
