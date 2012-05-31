__[30/5/12: N.B. This is a new version of the nswtopo program and makes use of different map servers. Users of the old program are advised to re-read the following instructions.]__

Summary
=======

This software allows you to download and compile high-resolution vector topographic maps from the NSW geospatial data servers, covering much of NSW and the ACT. The resulting maps include many of the features found in the printed NSW topographic map series and are well-suited for printing. You can specify the exact extent of the area which you wish to map, as well as your desired scale (typically 1:25000). The topographic map is output in [scalable vector graphics](http://en.wikipedia.org/wiki/Scalable_Vector_Graphics) format for use and further editing with vector graphics programs such as Inkscape or Illustrator.

This software was originally designed for the production of rogaining maps and as such includes several extra features (such as aerial imagery overlays, marker layers for control checkpoints, arbitrary map rotation and magnetic declination marker lines). However the software is also useful for anyone wanting to create custom NSW topo maps for outdoor recreation.

A few limitations currently exist when using the software. Map data is not always available, particularly in populated areas, due to caching performed by the map server. Also, a vegetation underlay, as typically found on printed NSW topographic mapsheets, is not available.

Pre-Requisites
==============

The software is run as a script, so you will need some familiarity with the command line. It was developed on a Mac, has also been tested on Windows and Ubuntu Linux.

The following open-source packages are required in order to run the script:

* The [Ruby programming language](http://ruby-lang.org). You'll need the more recent Ruby 1.9.3, not 1.8.x.
* [ImageMagick](http://imagemagick.org), a command-line image manipulation tool. The latest ImageMagick at time of development is version 6.7.3. Only the 8-bit (Q8) version is needed and will work faster and with less memory than the 16-bit version, particularly for larger maps.
* The [GDAL](http://gdal.org) command-line utilities. These are utilities for processing geospatial raster data.
* The [libgeotiff](http://geotiff.osgeo.org) library, for its `geotifcp` command for georeferencing images.
* (A zip command utility, if you wish to produce KMZ output maps for use with Google Earth.)

If you plan to make further enhancements, manual corrections or additions to your maps, you'll also need a vector graphics editing program such as [Inkscape](http://inkscape.org/), or Adobe Illustrator. An image editing tool such as [GIMP](http://www.gimp.org/) or Photoshop may also be useful for creating a custom background canvas for your map.

Finally, a geographic viewing or mapping program such as [Google Earth](http://earth.google.com) is very useful for easily specifying the area you wish to create a map for.

* _Windows_:
  * A complete Ruby 1.9.3 installation for Windows can be [downloaded here](http://rubyinstaller.org/) (be sure to select 'Add Ruby executables to your PATH' when installing).
  * Download a pre-built [ImageMagick binary](http://www.imagemagick.org/script/binary-releases.php#windows) for Windows. The Q8 version is preferred for speed, but either will work. Be sure to select 'Add application directory to your system path' when installing.
  * GDAL and libgeotiff are best obtained in Windows by installing [FWTools](http://fwtools.maptools.org). After installation, use the _FWTools Shell_ to run the `nswtopo.rb` script. (Another distribution containing the required packages is [OSGeo4W](http://trac.osgeo.org/osgeo4w/).)
  * (If you want to create KMZ files, install [7-Zip](http://www.7-zip.org) and add its location, `C:\Program Files\7-Zip`, to your PATH following [these instructions](http://java.com/en/download/help/path.xml), using a semicolon to separate your addition.)
* _Mac OS X_:
  * ImageMagick, GDAL and libgeotiff can obtained for Mac OS by first setting up [MacPorts](http://www.macports.org/), a package manager for Mac OS. You will first need to install Xcode from your OS X disc or via download; follow the instructions on the MacPorts site. After MacPorts is installed, use it to install the packages with `sudo port install libgeotiff gdal` and `sudo port install imagemagick +q8`
  * Alternatively, you can download and install pre-built binaries; try [here](http://www.kyngchaos.com/software:frameworks#gdal_complete) for GDAL, and the instructions [here](http://www.imagemagick.org/script/binary-releases.php#macosx) for ImageMagick. This may or may not be quicker/easier than installing XCode and MacPorts!
  * Depending on which Xcode version you have, Ruby 1.9.3 may already be available; type `ruby -v` in a terminal window to find this out. Otherwise, you can install Ruby 1.9.3 a number of ways, as explained [here](http://www.ruby-lang.org/en/downloads/).
  * (Max OS has the `zip` command built in.)
* _Linux_: You should be able to install the appropriate Ruby, ImageMagick, GDAL, libgeotiff and Inkscape packages using your distro's package manager (RPM, Aptitude, etc).

You can check that the tools are correctly installed by using the following commands:

    ruby -v
    identify -version
    gdalwarp --version
    geotifcp

You should receive version or usage information for each tool if it is installed correctly and in your path.

A large amount of memory is helpful. I developed the software on a 2Gb machine but it was tight; you'll really want at least 4Gb or ideally 8Gb to run the software smoothly. (On small amounts of memory, the software will still run, but the compositing step will cause memory paging to disk and become quite slow.) You will also need a decent internet connection. Most of the topographic map layers won't use a lot of bandwidth, but the aerial imagery could amount to 100Mb or more for a decent-sized map. You'll want an ADSL connection or better.

Usage
=====

The software can be downloaded from [github](https://github.com/mholling/nswtopo). It is best to download from the latest [tagged version](https://github.com/mholling/nswtopo/tags) as this should be stable. You only need to download the script itself, `nswtopo.rb`. Download by clicking the 'ZIP' button, or simply copying and pasting the script out of your browser.

You will first need to create a directory for the map you are building. Running the script will result in a number of image files representing various map layers, so a directory is needed to contain them.

## Specifying the Map Bounds

The simplest way to create a map is to trace out your desired area using Google Earth. Use the 'Polygon' tool to mark out the map area, then save this polygon in KML format as `bounds.kml` in the directory you created for your map. When running the script (see below), your bounds file will be automatically detected and a map produced using the default scale and settings.

Alternatively, create and edit a configuration text file called `config.yml` which will contain the bounds of the area you want mapped. (This format of this file is [YAML](http://en.wikipedia.org/wiki/YAML), though you don't really need to know this.) Specify the map bounds in UTM by providing the UTM zone (54, 55 or 56 for NSW) and minimum and maximum eastings and northings, as follows:

    zone: 55
    eastings:
    - 730500
    - 741500
    northings:
    - 6014500
    - 6022500

or, as latitude/longitude bounds:

    latitudes: 
    - -35.951221
    - -35.892871
    longitudes: 
    - 149.383789
    - 149.489746

Alternatively, you can specify a single coordinate for the map's centre, and a physical size for the map at the scale you specify (1:25000 by default). The map size should be specified in millimetres. For example:

    zone: 55
    easting: 691750
    northing: 6070500
    size: 220 x 360

or,

    latitude: -33.474050
    longitude: 150.137979
    size: 60 x 60

(Make sure you get your map bounds correct the first time to avoid starting over with the downloads.)

A third way of setting the map bounds is via a `.kml` or `.gpx` file. As described above, use a tool such as Google Earth or OziExplorer to lay out a polygon or waypoints marking the area you want mapped, and save it as a `.kml` or `.gpx` file. A file named `bounds.kml` will be detected automatically, or specify the file name explicitly as follows:

    bounds: bounds.gpx

If you are using a waypoints file to mark rogaine control locations, you can use the same file to automatically fit your map around the control locations. In this case you should also specify a margin in millimetres (defaults to 15mm) between the outermost controls and edge of the map:

    bounds: controls.kml
    margin: 15

## Running the Script

Once you have created your configuration file, run the script in the directory to create your map. The script itself is the `nswtopo.rb` file. The easiest way is to copy this file into your folder and run it from there thusly: `ruby nswtopo.rb`. Alternatively, keep the script elsewhere and run it as `ruby /path/to/nswtopo.rb`. By giving the script exec privileges (`chmod +x nswtopo.rb` or equivalent), you can run it directly with `./nswtopo.rb` (you may need to modify the hash-bang on line 1 to reflect the location of your Ruby binary).

When the script starts it will list the scale of your map (e.g. 1:25000), its rotation and its physical size. The size (in megapixels) and resolution of any associated rasters (e.g. aerial imagery) will also be displayed.

The script will then proceed to download the topographic data. Depending on your connection and the size of your map, an hour or more may be required. (I suggest starting with a small map, say 80mm x 80mm, just to familiarize yourself with the software; this should only take a few minutes.)

You can ctrl-c at any point to stop the script. Files which have already downloaded will be skipped when you next execute the script. (Note however that the interrupted download will be commenced anew.) Conversely, deleting an already-created file will cause that file to be recreated when you run the script again. Since the main topographic file takes a significant amount of time to download and assemble, it is best not to interrupt it during this download.

After all files have been downloaded, the script will then compile them into a final map image in `.svg` format. The map image is easily viewed in a modern web browser such as Chrome or Firefox, or edited in a vector imaging tool like Inkscape or Illustrator.

Map Configuration
=================

By editing `config.yml` you can customise many aspects of your map, including which additional layers to exclude. If no other configuration is provided, reasonable defaults are used. The customisation options are shown below with their default values. (*It is not necessary to provide these default values in your configuration file.*)

Set the scale of the map as follows:

    scale: 25000              # desired map scale (1:25000 in this case)

Set the map rotation angle as an angle between +/- 45 degrees anticlockwise from true north (e.g. for a rotation angle of 20, true north on the map will be 20 degrees to the right of vertical). There is no degradation in quality in a rotated map (although horizontal labels will no longer be horizontal). The special value `magnetic` will cause the map to be aligned with magnetic north.

    rotation: 0               # angle of rotation of map (or `magnetic` to align with magnetic north)

Another special value for rotation is `auto`, available when the bounds is specified as a `.kml` or `.gpx` file. In this case, a rotation angle will be automatically calculated to minimise the map area. This is useful when mapping an elongated region which lies oblique to the cardinal directions.

    rotation: auto            # rotate the map so as to minimise map area

Set the filename for the output map and related files.

    name: map                 # filename to use for the final map image(s) and related georeferencing files

Additional Layers
=================

Any or all of the following additional layers can be included in your map by listing them in the `include` option in your `config.yml` file. (At the very least, you will want to include `grid` for a normal map or `declination` for a rogaining map. The `relief` layer is also recommended.)

    include:
    - aerial-lpi-eastcoast
    - aerial-lpi-ads40
    - aerial-google
    - aerial-nokia
    - aerial-best
    - reference-topo-1
    - reference-topo-2
    - canvas
    - vegetation
    - plantation
    - holdings
    - relief
    - grid
    - declination
    - controls

(You can use `aerial` as a shortcut to download all the aerial imagery layers.)

## Aerial Imagery

These are orthographic aerial images for the specified map area, derived from Google Maps, Nokia Maps, and the NSW LPI department. Depending on your map location there may be up to four different aerial images available.

These layers are very useful for confirming the accuracy of the topographic features. For example, you may be able to manually add firetrails, new dams, etc, which are missing from the NSW map layers, on the basis of what you can see in the aerial imagery. Since the images are correctly georeferenced, this is achieved simply by tracing out the extra information on the appropriate layer while viewing the aerial imagery underneath.

(The other excellent use for these aerial imagery layers is to produce your own vegetation layer for a rogaine map. This is described below in the "canvas" section.)

* `aerial-lpi-ads40`: the best, most recent high resolution imagery available from the NSW LPI; available for many but not all areas of interest
* `aerial-lpi-eastcoast`: medium resolution imagery for most of the 25k topographic coverage; quite old film imagery (from the 90s?)
* `aerial-google`: generally good quality, recent aerial imagery from Google Maps; limited to 250 tiles per six hour period
* `aerial-nokia`: reasonable quality aerial imagery from Nokia Maps; limited to 250 tiles per six hours; georeferencing is not always the best and usually requires some manual nudging for best alignment
* `aerial-best`: A mosaic of NSW imagery of good quality

## Reference Topo Maps

These layers (`reference-topo-1` and `reference-topo-2`) contain lower-resolution topographic map raster images available from various NSW government mapping sites. They are useful to have as a reference for comparison against the output of this software.

## Vegetation

The vegetation layer in standard NSW printed topo sheets appears to be derived from a dataset called *NSW Interim Native Vegetation Extent (2008-v1)* (a.k.a. vegext1 or vegext1_08v1), which is a 25-metre resolution raster representation of NSW, categorised into 'woody' and 'non-woody' vegetation. For our purposes this generally corresponds to forested and open areas on our map.

This vegetation data is not available from a map server, but the entire 162 MB dataset may be downloaded from [here](http://www.canri.nsw.gov.au/download/download.cfm?File=vegext1.zip) (you will need to provide your name and email address). You need only download this once as the same data is used for any maps you create.

Once you have downloaded the data, unzip the file to a suitable location, locate the file named `hdr.adf` and add its path (relative or absolute) to your configuration file as follows:

    vegetation:
      path: /Users/Matthew/Downloads/vegext1/export/grid2/vegext1_08v1/hdr.adf

Finally, add `vegetation` to your list of layers to include, and build/rebuild your map to view the resulting vegetation underlay.

## Canvas

If you include a PNG image named `canvas.png` in the map directory, it will be automatically detected and used as an underlay for the map. It is intended that this map canvas should be derived from one of the aerial images using an image editing tool such as Photoshop or GIMP, in order to represent vegetation cover. This is useful in case you are not satisfied with the vegetation layer provided above.

Generating your own vegetation layer can be accomplished using the 'color range' selection tool in Photoshop, for example, or other similar selection tools. (Selecting on a single channel, such as green or magenta, may be helpful.) You can also create additional vegetation markings (e.g. for the distinctive, nasty heath that sometimes appears in ACT rogaines) using the aerial imagery.

## Plantations

If you include the `plantation` layer, a representation of pine forest plantations will be added to your map in darker green. The accuracy of this layer is not guaranteed however.

## Holdings

The `holdings` layer overlays property boundaries and the names of landowners. This information may be useful to rogainers when planning a course. (No information is provided for the ACT.)

## Relief

By including the `relief` layer in your map, you can include a pleasing [shaded-relief](http://en.wikipedia.org/wiki/Cartographic_relief_depiction#Shaded_relief) depiction. This can be a helpful addition for the intuitive understanding of the topography represented in a map. The shaded relief layer is automatically generated from the ASTER digital elevation model.

You can specify the azimuthal angle, altitude and terrain exaggeration used to generate the shaded relief layer. (The traditional azimuth angle of 315 is set as default, should probably be adhered to.) You can also specify the opacity of the layer to change the aggressiveness of the effect.
  
    relief:
      azimuth: 315            # azimuth angle for shaded relief layers (degrees clockwise from North)
      altitude: 45            # angle of illumination from horizon (45 is standard)
      exaggeration: 1         # vertical exaggeration factor
      opacity: 0.3            # opacity of the shaded relief; determines how subtle the effect is

## UTM Grid

The `grid` layer marks the UTM grid onto the map, for use with a GPS or to give grid references from the map. You should include the UTM grid if the map is for normal use; for a rogaining map, the grid is not needed and clutters up the map, so leave it out.

You can customise the appearance of the UTM grid and labels if you desire:

    grid:
      interval: 1000          # interval between grid lines (1000 metres by default)
      width: 0.1              # width in millimetres of the marked lines on the map
      colour: "#000000"       # colour of the gridlines as a hex triplet (black by default)
      label-spacing: 5        # number of gridlines between successive labels
      fontsize: 7.8           # font size (in points) of the grid labels
      family: Arial Narrow

## Declination

This layer marks magnetic north lines on the map, and is useful for rogaining maps. The magnetic declination angle for the map centre is automatically retrieved from the Geoscience Australia website. (Override by specifying an `angle: ` value.) Specify spacing and rendering for the magnetic declination lines. 

    declination:
      spacing: 1000           # perpendicular spacing of magnetic declination lines in metres
      width: 0.1              # width of the marked lines on the map, in millimetres
      colour: "#000000"       # colour of the magnetic declination lines as a hex triplet (black by default)

## Controls

Drop a control waypoints file (in `.kml` or `.gpx` format) into the directory and layers containing control circles and numbers will be automatically generated. If a waypoint is name 'HH' it will be drawn as a triangle, otherwise a circle will be drawn. If a control has 'W' after its number (e.g. '74W'), or separate waypoints marked 'W1', 'W2' etc are found, those waypoints will be represented as water drops.

    controls:
      file: controls.kml      # filename (`.kml` or `.gpx` format) of control waypoint file
      fontsize: 14            # font size for control numbers
      diameter: 7.0           # diameter of control circles in millimetres
      thickness: 0.2          # thickness of control circles in millimetres
      colour: "#880088"       # colour of the control markers and labels (as a hex triplet or web colour)
      water-colour: blue      # colour of waterdrop markers

Overlays
========

TODO describe adding polygons and tracks to map using KML files

Suggested Workflow for Rogaining Maps
=====================================

TODO describe how to use aerial photos and reference topos to add unmarked tracks, etc, then re-compile the SVG without them

Georeferencing
==============

The map projection used is transverse mercator, with a central meridian corresponding to the map's centre. This conformal projection is ideal for topographic maps. A grid for the relevant UTM zone(s) (usually zone 55 or 56) can be added to the map (for use with a GPS) by including the UTM grid layers. All output layers (including the aerial imagery and shaded relief layers) are precisely aligned and in the same projection.

If you need your map to be in a UTM projection (aligned to grid north rather than true north), you can specify this as follows:

    utm: true

TODO: How to produce a georeferenced map raster (not yet implemented)

Customising Topographic Rendering
=================================

TODO

Release History
===============

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
* 30/5/2012: Substantial rewrite to use the new NSW ArcGIS server.
