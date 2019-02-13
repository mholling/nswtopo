# Release History

* 12/12/2011: version 0.1 (initial release)
  * 13/12/2011: version 0.1.1: added bridges, floodways, fixed narrow gaps in roads
  * 14/12/2011: version 0.1.2: reworked UTM grid to display correctly across zone boundaries
* 21/12/2011: version 0.2: added map rotation; added specification of map bounds via gpx/kml file; added ability to auto-rotate map to minimise area.
* 11/01/2012: version 0.3: misc. additions (e.g. lookouts, campgrounds, rock/pinnacle labels, etc); collected point markers into single layer; separated permanent and intermittent water layers; prevented label/feature overlap; decreased download times; removed unavailable ACT layers; added low-res reference topo.
* 2/2/2012: version 0.4: added ferry routes, mangroves, restricted areas, canals, breakwaters, levees, road outlines; tweaked road & track colours; added grid-style UTM labels; removed absolute path from OziExplorer .map file; fixed bug wherein resolution tags in some output images were incorrectly set.
  * 8/2/2012: version 0.4.1: fixed bug whereby excluding labels also excluded control-labels
  * 9/2/2012: version 0.4.2: added kmz as output format
  * 13/2/2012: version 0.4.3: reworked road/track colours and outlines
  * 7/3/2012: version 0.4.4: fixed bug in OziExplorer .map files created by non-windows OS; added layer opacity; added overlay layers from GPX/KML/etc files
* 3/6/2012: version 0.5: Substantial rewrite to use the new NSW ArcGIS server
  * 4/6/2012: version 0.5.1: added metadata to identify layers correctly to Inkscape
* 30/6/2012: version 0.6: fixed bug with shaded-relief and vegetation layers on some versions of ImageMagick; added option for default nswtopo.cfg file stored in nswtopo.rb location; improved SVG topographic labels layer; added other output formats: .png, .tif, .kmz, .pdf, .prj, .wld, .map; added rendering using Inkscape or Batik; switched from 0.9996 to 1.0 for transverse mercator scale factor; changed config.yml to nswtopo.cfg; added configurations for individual output raster dpis and input raster resolutions
  * 5/7/2012: version 0.6.1: fixed vegetation rendering bug on linux; added time remaining estimations; bugfixes; added fix for java OutOfMemory error when using Batik
  * 5/8/2012: version 0.6.2: fixes to restore Windows compatibility and update Windows installation instructions
  * 4/10/2012: version 0.6.3: changed old LPIMAP layer names to new LPIMAP layer names; added the option of specifying a map bound using a track; fixed problem with ESRI SDS 1.95 1 font; fixed bug with KMZ generation; fixed broken cadastre layer; fixed broken holdings layer
  * 25/9/2013: version 0.6.4: fixed aerial-best, paths and holdings layers; expanded and renamed reference topo layers; updated vegetation layer to use v2 dataset.
* 10/2/2014: version 0.7: added in-place updating of composite map svg; added manual DEM option for shaded relief layer; store intermediate vegetation layer; added qlmanage and PhantomJS options for rasterising; added online source for 90m SRTM elevation data; added ability to import georeference raster images; added SPOT5 vegetation source; for rotated maps, prevent download of tiles which don't fall within map extents; scaled labels better for small-scale maps; added option to use 20-metre contour intervals; added option to exclude layers from map.
  * 22/2/2014: version 0.7.1: used all tracks instead of just first when calculating bounds from a GPX/KML file; fixed bug preventing tiny maps from downloading; changed manner of specifying rendering options; added alternate source of basic contour/road/track/watercourse/label layers; reverted to flat layer structure for SVG file; changed HydroArea layer to perennial water areas only; changed to LPIMapLocal as default data source due to availability.
* 3/7/2014: version 0.8: added RFS layers for stock dams and buildings; extracted various layer sources to external configuration files for greater flexibility; change way of specifying overlays; add ANC and water-drop icons for controls; add some SA and TAS map data sources.
  * 28/8/2014: version 0.8.1: change nsw/vegetation-2008-v2 woody vegetation colour; fix vegetation & relief rendering bug in Windows
  * 11/11/2014: version 0.8.2: add psd format output; fix bug in ArcGIS image servers; change to online source of 1-second SRTM relief data; apply median and bilateral filtering to shaded relief; fix label issues causing bad PhantomJS rasters; float vector label layers above feature layers.
* 27/1/2015: version 1.0: major update with NSW topographic maps now available for all areas and TAS topographic and vegetation layers also available.
  * 28/1/2015: version 1.0.1: fix 'command line is too long' bug on Windows.
* 1/8/2015: version 1.1: add features required for QLD maps; add version-checking; add TAS map features; fix some PhantomJS rendering bugs; misc tweaks/improvements/fixes.
  * 1/11/2015: version 1.1.1: add ability to render symbols for waypoint overlays; add fallback servers for unreliable map servers.
  * 13/11/2015: version 1.1.2: bugfixes for Windows and Ruby 1.9
  * 29/11/2015: version 1.1.3: bugfix for lambert conformal conic services
  * 13/12/2015: version 1.1.4: bugfix for Windows PhantomJS output
  * 5/2/2016: version 1.1.5: add template for NSW map sheets; update ACT server details; read gx:Track elements in KML files
  * 4/3/2016: version 1.1.6: bugfix for some changed NSW map servers
  * 18/6/2016: version 1.1.7: update NSW data sources
* 22/8/2016: version 1.2: improve labeling quality and speed; update various map sources accordingly
  * 25/8/2016: version 1.2.1: bugfix for stack overflow
* 23/9/2016: version 1.3: improvements to labelling algorithm; remove old NSW server references
* 5/10/2016: version 1.4: further labelling improvements; break out code into multiple files
  * 2/11/2016: version 1.4.1: add Electron as rasterising option; add multi-point shaded relief option; miscellaneous small fixes and refactoring
* 6/5/2017: version 1.5: calculate shaded relief from contour data instead of DEM; fix bug in rotated maps where shaded relief mask was not rotated; fix magnetic declination calculator; add mbtiles output format; improve Electron raster reliability (sorta)
* 11/8/2018: version 1.6: fix bug with shaded relief when coastline is present; switch to Google Chrome as preferred rasterising method; more accurate font sizing when using Chrome; add ACT map source for 5-metre contours; numerous internal changes and fixes
  *  12/8/2018: version 1.6.1: Windows bugfix
* 13/2/2019: version 2.0.0: major rewrite with new command structure
