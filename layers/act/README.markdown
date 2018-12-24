ACT Map Layers
==============

This directory contains map layers specific to the Australian Capital Territory.

## 2012 & 2015 Aerial Imagery

A territory-wide, high-resolution aerial imagery layer is available from an ACT government server. The default resolution is 1.0 metres per pixel. Include `act/aerial-2012` and/or `act/aerial-2015` to obtain the aerial image for your map.

## Rogaine

The `act/rogaine` source is intended for rogaine maps within the ACT. It is a stripped-down version of the NSW map source, with NSW contours replaced by high-resolution 5-metre contours from the 2015 ACT LiDAR data.

A typical ACT rogaine map might include the following:

    include:
    - nsw/vegetation-spot5
    - act/rogaine
    - act/relief
    - declination
    - controls

You will likely notice misalignments between the old, NSW watercourse lines and the more accurate ACT contour lines. This is unlikely to cause any real problems but can look a bit offputting. You can manually realign the watercourses with Inkscape, but this will be laborious.

## Relief

A matching shaded-relief layer derived from the ACT 5m contour data. Include `act/relief` to add this layer. For a large map, this layer will likely be slow to download and compute.
