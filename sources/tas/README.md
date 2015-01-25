TAS Map Layers
==============

This directory contains map layers specific to Tasmania.

## Topographic

This topographic map is derived from features made avaiable on the [*Land Information System Tasmania*](http://www.thelist.tas.gov.au/) (*theLIST*). It produces a nicely styled topographic map with a full set of landform, casastral, hydrographic and transport features. Spot heights and building features are notably missing, as this data is not available online. Include it in your map layer list as follows:

    include:
    - tas/topographic

The topographic feature data is often very finely detail, and can sometimes take time to download render. (This is particularly noticeable in maps which contain coastline.)

## Reserves

Include the `tas/reserves` layer to add boundaries and labels for national parks, natures reserves and conservation areas.

## Aerial Imagery

High-resolution aerial imagery, also available from *theLIST* is available by including the `tas/orthophoto` layer. (The orthophoto layer defaults to 2.0 metres per pixel.)

## Reference Topo Maps

A raster image of the printed TASMAP topo sheets is also available as `tas/tasmap-raster`. This is good as a reference, although the contours are a bit light.
