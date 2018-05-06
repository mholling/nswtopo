TAS Map Layers
==============

This directory contains map layers specific to Tasmania.

## Topographic

This topographic map is derived from features made avaiable on the [*Land Information System Tasmania*](http://www.thelist.tas.gov.au/) (*theLIST*). It produces a nicely styled topographic map with a full set of landform, casastral, hydrographic and transport features. (Spot heights are notably missing, as this data is not available online). Include it in your map layer list as follows:

    include:
    - tas/topographic

The topographic feature data is often very finely detail, and can sometimes take time to download render. (This is particularly noticeable in maps which contain coastline.)

## Reserves

Include the `tas/reserves` layer to add boundaries and labels for national parks, natures reserves and conservation areas.

## Vegetation

The `tas/tasveg` source produces a basic vegetation layer suited for use as a topographic underlay:

    include:
    - tas/tasveg
    - tas/topographic

The data is sourced from [*TASVEG 3.0*](http://dpipwe.tas.gov.au/conservation/flora-of-tasmania/monitoring-and-mapping-tasmanias-vegetation-\(tasveg\)/tasveg-the-digital-vegetation-map-of-tasmania), an overwhelmingly detailed dataset describing the spatial distribution of over 150 vegetation communities found in Tasmania. Representing the full detail of this data on a map in a useful manner is challenging!

Thankfuly, the *TASVEG* vegetation communities are divided into distinct groups, and these groups are simply coloured as follows:

* *Non eucalypt forest and woodland*: light green
* *Dry eucalypt forest and woodland*: light green
* *Wet eucalypt forest and woodland*: slightly darker green
* *Rainforest and related scrub*: slightly darker green
* *Scrub, heathland and coastal complexes*: light green with leafy symbology
* *Highland and treeless vegetation*: white
* *Moorland, sedgeland, rushland and peatland*: white
* *Native grassland*: white
* *Other natural environments*: white
* *Saltmarsh and wetland*: white
* *Agricultural, urban and exotic vegetation*: white

(The intent of this colouring is to merely distinguish between open and forested areas, not to indicate ease of travel!)

Additional pine symbology is also included for plantation forests (FPL, FPU) and areas of pencil pine (RPF, RPP).

Each layer is sub-classified by the vegetation community code and group code, and it is possible to style individual communities. For example, to give a colour to all buttongrass communities:

    tas.tasveg.vegetation:
      [ MBE, MBP, MBR, MBS, MBU, MBW ]:
        fill: "#F6DFBA"

Or, to colour all vegetation in the *Native grassland* group:

    tas.tasveg.vegetation:
      Native-grassland:
        fill: "#F6DFBA"

## Relief

Generates a shaded relief overlay derived from contours used in the map.

## Aerial Imagery

High-resolution aerial imagery, also available from *theLIST* is available by including the `tas/orthophoto` layer. (The orthophoto layer defaults to 2.0 metres per pixel.)

## Reference Topo Maps

A raster image of the printed TASMAP topo sheets is also available as `tas/tasmap-raster`. This is good as a reference, although the contours are a bit light.
