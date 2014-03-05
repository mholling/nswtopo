Map Layers
==========

Files in this directory structure contain definitions for downloading various Australian and state-specific map layers. Specify their inclusion in your map as per the following example:

    include:
    - aerial-google
    - nsw/aerial-best
    - act/aerial-2012
    - nsw/vegetation-2008-v2

Australia-wide aerial imagery layers are described below. For state-specific map layers (including topographic layers), see the [NSW](nsw) and [ACT](act) directories.

Aerial Imagery
==============

Aerial imagery layers are very useful for confirming the accuracy of the topographic features. For example, you may be able to manually add firetrails, new dams, etc, which are missing from the NSW map layers, on the basis of what you can see in the aerial imagery. Since the images are correctly georeferenced, this is achieved simply by tracing out the extra information on the appropriate layer while viewing the aerial imagery underneath. (Another excellent use for these aerial imagery layers is to produce your own vegetation layer for a rogaine map. This is described below in the [canvas](..#canvas) section.)

These are orthographic aerial images for the specified map area, derived from Google Maps and Nokia Maps. Their quality is variable and registration can be inaccurate. Where possible, prefer the aerial layers specific to [NSW](nsw) and the [ACT](act).

* `aerial-google`: generally good quality, recent aerial imagery from Google Maps; limited to 250 tiles per six hour period
* `aerial-nokia`: reasonable quality aerial imagery from Nokia Maps; limited to 250 tiles per six hours
