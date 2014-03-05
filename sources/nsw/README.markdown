NSW Map Layers
==============

This directory contains map layers specific to New South Wales. For a NSW topographic map, you will want to include either `nsw/lpimap` or `nsw/lpimaplocal` (whichever works), and probably also one of the vegetation layers.

## LPIMap

This map is published by the NSW LPI department as their standard online topographic map. It produces a nicely styled map with most of the features you'd expect from the printed NSW topographic map sheets. It will be included by default, or specify it in your map layer list as follows:

    include:
    - nsw/lpimap
    - grid

Unfortunately, due to caching issues, the map is slow to download and some areas will not download at all. (This usually occurs in urban areas, so you should not intend to use it for topographic maps near sydney or any town.) Blank tiles in the downloaded map are an indication that you have encountered these issues. If this occurs, `nsw/lpimaplocal` is a good replacement.

## LPIMapLocal

This map layer is a substitute for the *LPIMap* layer, should it be needed. The map service is currently in beta and may be subject to change. It includes most of the same information, however a few features are not present (these includes gates & grid, buildings and stock dams). The upside is that the map is available everywhere and the download is considerably faster. Include the *LPIMapLocal* layers as follows:

    include:
    - nsw/lpimaplocal

## RFS Layers

The `nsw/rfs` layers add representations of stock dams and buildings to your map. These features are usually present on a standard 1:25k topographic map, but are not provided by the `lpimaplocal` topographic server. The information is sourced from a map provided for the Rural Fire Service. You may wish to change the order of these layers with Inkscape after adding them to your map:

    below:
      nsw.rfs.stock-dams: nsw.lpimaplocal.water-areas
      nsw.rfs.buildings: nsw.lpimaplocal.homesteads

## Aerial Imagery

High-resolution aerial imagery is also available from the NSW LPI department.

* `nsw/aerial-best`: A mosaic of the best NSW LPI imagery at a default of 1.0 metres; use this imagery first
* `nsw/aerial-lpi-ads40`: Recent, high resolution imagery available from the NSW LPI; available for many but not all areas of interest 
* `nsw/aerial-lpi-eastcoast`: medium resolution imagery for most of the 25k topographic coverage; quite old film imagery (from the 90s?)

Depending on the native resolution of the dataset, you may or may not obtain a more detailed image by specifying a better resolution. A lot of the `aerial-best` imagery has a native resolution of 0.5 m/px, and can yield very a very detailed image. However, for a map of reasonable size, the image produced at this resolution can be extremely large (easily 100+ megapixels)! Specify a different resolution as follows:

    include:
    - nsw/aerial-best: 0.5

## Reference Topo Maps

These layers (`nsw/reference-topo-current`, `nsw/reference-topo-s1` and `nsw/reference-topo-s2`) contain lower-resolution topographic map raster images at various points in time (recent, older and oldest, respectively). They are useful to have as a reference for comparison against the output of this software.

## Vegetation

The vegetation layer in standard NSW printed topo sheets appears to be derived from a dataset called *NSW Interim Native Vegetation Extent (2008-v2)*, which is a 25-metre resolution raster representation of NSW, categorised into 'woody' and 'non-woody' vegetation. For our purposes this generally corresponds to forested and open areas on our map.

This vegetation data is not available from a map server, but the entire 162 MB dataset may be downloaded from [here](http://mapdata.environment.nsw.gov.au/geonetwork/srv/en/metadata.show?id=246) (you will need to provide your name and email address). You need only download this once as the same data is used for any maps you create.

Once you have downloaded the data, unzip the file to a suitable location, locate the file named `hdr.adf` and add its path (relative or absolute) to your configuration file. (You can also modify the default colours for woody and non-woody vegetation, should you wish.)

    include:
    - nsw/vegetation-2008-v2
    - nsw/lpimap
    - grid
    nsw.vegetation-2008-v2:
      path: /Users/matthew/nswtopo/NSWInterimNativeVegetationExtentV2_2008/Data/nswintext08/hdr.adf
      colour:
        woody: light green      # alternately specify a hex triplet, e.g. "#C2FFC2"
        non-woody: white

Build or rebuild your map to view the resulting vegetation underlay.

## SPOT5 Vegetation

A newer, far superior vegetation data set is becoming available for NSW. Known as *SPOT5 woody extent and foliage projective cover (FPC) (5-10m) 2011*, it has a much higher resolution of 5-10 metres, and further classifies the woody areas by their foliage projective cover (the fraction of green foliage) as a percentage. To obtain this data, email the contact listed [here](https://sdi.nsw.gov.au/catalog/search/resource/details.page?uuid=%7BA9A65A5C-D3F2-4879-8994-6FF855201E30%7D) with a request for the data for your map area. (As the data set is not yet completed as of January 2014, data for your area may or may not be available.)

If you obtain the data, unzip it and specify its path as follows:

    include:
    - nsw/vegetation-spot5
    - nsw/lpimap
    - grid
    nsw.vegetation-spot5:
      path: /Users/matthew/nswtopo/SPOT_woody_extent/r422c105.img
      embed: false     # optional

Or, if you have multiple tiles of data:

    nsw.vegetation-spot5:
      path:
      - /Users/matthew/nswtopo/SPOT_woody_extent/r422c105.img
      - /Users/matthew/nswtopo/SPOT_woody_extent/r423c105.img
      resolution: 5.0
      embed: false     # optional

Running the script will create and composite the new `nsw.vegetation-spot5` layer in your map. By default, the vegetation layer is embedded as data within the SVG, however this can produce a large, unwieldy file when using the 5-metre data. Specify `embed: false` to link the vegetation by reference instead. (The SVG file will no longer be self-contained.)

Since the SPOT5 data is so detailed, you may wish to adjust its contrast to get the best visual effect for your map. (However, there is a trade-off between detail shown in the vegetation and readability of other map features such as contours.) You can do so using Photoshop or GIMP (e.g. by applying the levels adjustment) to adjust the vegetation raster. Alternatively, some control of levels is available from within the script. For example, to increase contrast between lightly and heavily wooded areas:

    nsw.vegetation-spot5:
      contrast:
        low: 30   # default is 0
        high: 70  # default is 100

(This would map 30% or lighter foliage to white and 70% or more to full green, effecting an increase in contrast.)

## Plantations

If you include the `nsw/plantations` layer, a representation of pine forest plantations will be added to your map in darker green. The accuracy of this layer is not guaranteed however.

## Holdings

The `nsw/holdings` layer overlays property boundaries and the names of landowners. This information may be useful to rogainers when planning a course. (No information is available for the ACT.)

## Basic Topographic Layers

The main topographic layers, `lpimap` and `lpimaplocal`, are well-styled and produce the best topographic maps. However the server is not yet out of beta and subject to change. If you do not achieve good results with the default server, you can chose alternate `basic` sources as follows:

    include:
    - nsw/basic-contours
    - nsw/basic-cadastre
    - nsw/basic-features

The `basic` topographic layers do not contain as many features as the normal layers. Currently, they only contain: contours, sealed and unsealed roads, vehicular tracks, pathways, cadastral boundaries and watercourses. Labels are only present for contours and roads. Other informative layers (e.g. cliffs, swamp and inundation areas, water areas, feature labels etc) are missing. Nonetheless, the alternative topographic layers may produce a sufficient map for your needs.
