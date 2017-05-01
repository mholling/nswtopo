NSW Map Layers
==============

This directory contains map layers specific to New South Wales. For a NSW topographic map, you will want to include `nsw/topographic` and probably also one of the vegetation layers.

## Topographic

This map is a derived from the NSW [*Digital Topographic Database*](http://www.lpi.nsw.gov.au/mapping_and_imagery/topographic_data) (DTDB), which contains the current topographic features for the entire state. It produces a nicely styled map with most of the features you'd expect from the printed NSW topographic map sheets (with a few minor exceptions, most notably electricity transmission lines). It will be included by default, or specify it in your map layer list as follows:

    include:
    - nsw/topographic
    - grid

## Topographic Extras

This map source retrieves and renders additional layers for pipelines, electricity transmission lines and cableways (mostly gondolas and ski chairlifts). They are not incorporated in the main topographic map since the server is unreliable and subject to discontinuation. Include `nsw/topo-extras` after `nsw/topographic` to add these extra layers.

## Reserves

Include the `nsw/reserves` layer to add boundaries and labels for NSW national parks, natures reserves, state conservation areas and state forests.

## Trig Stations

The `nsw/survey` layer adds symbols for trig stations which are found on various NSW summits. (n.b. The trig stations found on this layer are not always present on the ground!)

## Relief

Generates a shaded relief overlay derived from contours used in the map.

## Aerial Imagery

High-resolution aerial imagery is also available from the NSW LPI department. Include it as follows:

    include:
    - nsw/aerial
    - nsw/topographic

This layer is a mosaic of the best NSW LPI imagery at a default of 1.0 metres. A lot of the imagery has a native resolution of 0.5 m/px, and can yield very a very detailed image. However, for a map of reasonable size, the image produced at this resolution can be extremely large (easily 100+ megapixels)! Specify a different resolution as follows:

    include:
    - nsw/aerial: 2.0

## Reference Topo Maps

These layers (`nsw/reference-topo-current` and `nsw/reference-topo-s1`) contain lower-resolution topographic map raster images at various points in time (recent and older, respectively). They are useful to have as a reference for comparison against the output of this software.

## Vegetation

The vegetation layer in standard NSW printed topo sheets appears to be derived from a dataset called *NSW Interim Native Vegetation Extent (2008-v2)*, which is a 25-metre resolution raster representation of NSW, categorised into 'woody' and 'non-woody' vegetation. For our purposes this generally corresponds to forested and open areas on our map.

This vegetation data is not available from a map server, but the entire 162 MB dataset may be downloaded from [here](http://mapdata.environment.nsw.gov.au/geonetwork/srv/en/metadata.show?id=246) (you will need to provide your name and email address). You need only download this once as the same data is used for any maps you create.

Once you have downloaded the data, unzip the file to a suitable location, locate the file named `hdr.adf` and add its path (relative or absolute) to your configuration file. (You can also modify the default colours for woody and non-woody vegetation, should you wish.)

    include:
    - nsw/vegetation-2008-v2
    - nsw/topographic
    - grid
    nsw.vegetation-2008-v2:
      path: /Users/matthew/nswtopo/NSWInterimNativeVegetationExtentV2_2008/Data/nswintext08/hdr.adf
      colour:
        woody: light green      # alternately specify a hex triplet, e.g. "#C2FFC2"
        non-woody: white

Build or rebuild your map to view the resulting vegetation underlay.

## SPOT5 Vegetation

A newer, far superior vegetation data set is available for NSW as of mid-2015. Known as *SPOT5 woody extent and foliage projective cover (FPC) (5-10m) 2011*, it has a much higher resolution of 5-10 metres, and further classifies the woody areas by their foliage projective cover (the fraction of green foliage) as a percentage. The dataset is [described here](http://www.auscover.org.au/xwiki/bin/view/Product+pages/nsw+5m+woody+extent+and+fpc), with a direct FTP download currently at [`ftp://qld.auscover.org.au/spot/woody_fpc_extent/nsw-2011/s5hgps_nsw_y20082012_bcvl0.tif`](ftp://qld.auscover.org.au/spot/woody_fpc_extent/nsw-2011/s5hgps_nsw_y20082012_bcvl0.tif). At 8.6Gb, it's a large download, but worth it if you wish to make many maps. The same FTP server also has individual tiles available at more reasonable sizes (choose the `bcvm` file), but you'll need to determine which tile contains your map area.

If you obtain the data, unzip it and specify its path as follows:

    include:
    - nsw/vegetation-spot5
    - nsw/topographic
    - grid
    nsw.vegetation-spot5:
      path: /Users/matthew/nswtopo/SPOT_woody_extent/s5hgps_nsw_y20082012_bcvl0.tif

Or, if you have tiles of data:

    nsw.vegetation-spot5:
      path:
      - /Users/matthew/nswtopo/SPOT_woody_extent/s5hgps_r422c105_y20082012_bcvm6_r5m.img
      - /Users/matthew/nswtopo/SPOT_woody_extent/s5hgps_r423c105_y20082012_bcvm6_r5m.img
      resolution: 5.0

Running the script will create and composite the new `nsw.vegetation-spot5` layer in your map. By default, the vegetation layer is embedded as data within the SVG, however this can produce a large, unwieldy file when using the 5-metre data. Specify `embed: false` to link the vegetation by reference instead. (The SVG file will no longer be self-contained.)

Since the SPOT5 data is so detailed, you may wish to adjust its contrast to get the best visual effect for your map. (However, there is a trade-off between detail shown in the vegetation and readability of other map features such as contours.) You can do so using Photoshop or GIMP (e.g. by applying the levels adjustment) to adjust the vegetation raster. Alternatively, some control of levels is available from within the script. For example, to increase contrast between lightly and heavily wooded areas:

    nsw.vegetation-spot5:
      contrast:
        low: 30   # default is 10
        high: 70  # default is 75

(This would map 30% or lighter foliage to white and 70% or more to full green, effecting an increase in contrast.)
