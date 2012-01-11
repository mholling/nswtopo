Summary
=======

This software allows you to download and compile high-resolution topographic maps from the NSW geospatial data servers, covering all of NSW and the ACT. The resulting maps include most of the features found in the printed NSW topographic map series and are well-suited for printing. You can specify the exact extent of the area which you wish to map, as well as your desired print resolution (in pixels per inch) and scale (typically 1:25000 or 1:50000). You can obtain the map output as a single composite file, or a multi-layer file containing layers for each topographic feature (e.g. contours, watercourses, roads, etc). The output map is also georeferenced for use with map-viewing or GIS software.

This software was originally designed for the production of rogaining maps and as such includes several extra features (such as aerial imagery overlays, marker layers for control checkpoints, arbitrary map rotation and magnetic declination marker lines). However the software is also useful for anyone wanting to create custom NSW topo maps for outdoor recreation.

Pre-Requisites
==============

The software is run as a script, so you will need some familiarity with the command line. It was developed on a Mac, has also been tested on Windows and Ubuntu Linux.

The following open-source packages are required in order to run the script:

* The [Ruby programming language](http://ruby-lang.org). You'll need the more recent Ruby 1.9.x, not 1.8.x.
* [ImageMagick](http://imagemagick.org), a command-line image manipulation tool. The latest ImageMagick at time of development is version 6.7.3. Only the 8-bit (Q8) version is needed and will work faster and with less memory than the 16-bit version, particularly for larger maps.
* The [GDAL](http://gdal.org) command-line utilities. These are utilities for processing geospatial raster data.
* The [libgeotiff](http://geotiff.osgeo.org) library, for its `geotifcp` command for georeferencing images.

If you plan to make further enhancements, manual corrections or additions to your maps, you'll also need a layer-based image editing tool such as [GIMP](http://www.gimp.org/) or Photoshop.

* _Windows_:
  * A complete Ruby 1.9 installation for Windows can be [downloaded here](http://rubyinstaller.org/) (be sure to select 'Add Ruby executables to your PATH' when installing).
  * Download a pre-built [ImageMagick binary](http://www.imagemagick.org/script/binary-releases.php) for Windows. The Q8 version is preferred for speed, but either will work. Be sure to select 'Add application directory to your system path' when installing.
  * GDAL and libgeotiff are best obtained in Windows by installing [FWTools](http://fwtools.maptools.org). After installation, use the _FWTools Shell_ to run the `nswtopo.rb` script.
* _Mac OS X_:
  * ImageMagick, GDAL and libgeotiff are best obtained for Mac OS by first setting up [MacPorts](http://www.macports.org/), a package manager for Mac OS. You will first need to install Xcode from your OS X disc or via download; follow the instructions on the MacPorts site. After MacPorts is installed, use it to install the packages with `sudo port install libgeotiff gdal` and `sudo port install imagemagick +q8`
  * Depending on which Xcode version you have, Ruby 1.9.x may already be available; type `ruby -v` to find this out. Otherwise, you can install Ruby 1.9 a number of ways, as explained [here](http://www.ruby-lang.org/en/downloads/).
* _Linux_: You should be able to install the appropriate Ruby, ImageMagick, GDAL and libgeotiff packages using your distro's package manager (RPM, Aptitude, etc).

You can check that the tools are correctly installed by using the following commands:

    ruby -v
    identify -version
    gdalwarp --version
    geotifcp

You should receive version or usage information for each tool if it is installed correctly and in your path.

A large amount of memory is helpful. I developed the software on a 2Gb machine but it was tight; you'll really want at least 4Gb or ideally 8Gb to run the software smoothly. (On small amounts of memory, the software will still run, but the compositing step will cause memory paging to disk and become extremely slow.) Make sure you also have plenty of disk space to accommodate the intermediate image files that are generated. Finally, you will need a decent internet connection. Most of the topographic map layers won't use a lot of bandwidth, but the aerial imagery could amount to 100Mb or more for a decent-sized map. You'll want an ADSL connection or better.

Usage
=====

The software can be downloaded from [github](https://github.com/mholling/nswtopo). It is best to download from the latest [tagged version](https://github.com/mholling/nswtopo/tags) as this should be stable. You only need to download the script itself, `nswtopo.rb`. Download by clicking the 'ZIP' button, or simply copying and pasting the script out of your browser.

You will first need to create a directory for the map you are building. Running the script will result in a large number of image files representing the map layers, so a directory is needed to contain them.

In this directory, create and edit a configuration text file called `config.yml` which will contain the bounds of the area you want mapped. (This format of this file is [YAML](http://en.wikipedia.org/wiki/YAML), though you don't really need to know this.) Specify the map bounds in UTM by providing the UTM zone (54, 55 or 56 for NSW) and minimum and maximum eastings and northings, as follows:

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

A third way of setting the map bounds is via a .kml or .gpx file. Use a tool such as Google Earth or OziExplorer to lay out a polygon, track or waypoints marking the area you want mapped, and save it as a .gpx or .kml file. A file named `bounds.kml` will be detected automatically, or specify the file name explicitly as follows:

    bounds: bounds.gpx

If you are using a waypoints file to mark rogaine control locations, you can use the same file to automatically fit your map around the control locations. In this case you should also specify a margin in millimetres (defaults to 15mm) between the outermost controls and edge of the map:

    bounds: controls.gpx
    margin: 15
    
Once you have created your configuration file, run the script in the directory to create your map. The script itself is the `nswtopo.rb` file. The easiest way is to copy this file into your folder and run it from there thusly: `ruby nswtopo.rb`. Alternatively, keep the script elsewhere and run it as `ruby /path/to/nswtopo.rb`. By giving the script exec privileges (`chmod +x nswtopo.rb` or equivalent), you can run it directly with `./nswtopo.rb` (you may need to modify the hash-bang on line 1 to reflect the location of your Ruby binary).

When the script starts it will list the scale of your map (e.g. 1:25000), its rotation, its physical size and resolution (e.g. 380mm x 240mm @ 300 ppi) and its size in megapixels. For a 300 pixel-per-inch image (the default), an A3 map should be about 15 megapixels. An unexpectedly large or small number may indicate an error in your configuration file; similarly, if no topographic layers are downloaded, this probably indicates you've incorrectly specified bounds outside NSW.

The script will then proceed to download a large number of layers. A progress bar will show for each group of layers. Depending on your connection and the size of your map, an hour or more may be required. (I suggest starting with a small map, say 80mm x 80mm, just to familiarize yourself with the software; this should only take a few minutes.) Any errors received will be displayed and the layer skipped; you can run the script again to retry the skipped layers as they are usually just temporary server errors.

You can ctrl-c at any point to stop the script; it will pick up where it left off the next time you run it, skipping layers that have already been downloaded. (Conversely, deleting an already-created layer file will cause that file to be recreated when you run the script again.)

A description of each layer is found later in this document.

After all layers have been downloaded, the script will then compile them into a final map image. The default is to create both a PNG and a multi-layered TIFF. (Several output formats are possible - see below). Depending on the specs of your computer and the size of your map, creating a multi-layered TIFF or PSD (photoshop) image may take a long time, particularly if swap memory is hit. Be patient. If you don't plan to do any further manipulation or editing of your map, you need only specify a PNG or PDF as output format in your configuration file, as this will take less time.

Using the Output
================

You can use the output files in a few different ways. If you just want a quick map, specify your output format as png or pdf only. The program will automatically compile all the data into a single file which you can then print and use.

If you're creating a map for rogaining, you will probably want to build a multi-layered file for further editing using GIMP or Photoshop. In this case, specify `layered.tif` or `psd`, respectively, as your output format. These formats will keep each topographic feature on a separate layer, allowing you to edit them individually. In combination with the aerial layers, which you can turn on and off as underlayers, this allows you to compare the mapped location of topographic features such as roads, dams and cliffs against their position on the aerial imagery, and to manually add, correct or remove such features as needed (e.g. old firetrails that have been changed, are no longer present, or new firetrails that have not yet been mapped).

(Note that the ImageMagick photoshop driver is not particularly good; it does not do any file compression, which can lead to a gigabyte+ file size and very slow performance for large maps. The file will be correctly compressed once you load and save it in Photoshop, however.)

It is also possible to construct your own Photoshop or GIMP document by hand, using the topographic layers as layer masks for color fill or pattern layers representing each feature. The topographic feature layers are colored white-on-black to allow you to do this easily.

Map Configuration
=================

By editing `config.yml` you can customise many aspects of your map, including the colour and patterns used for various features and which layers to exclude. If no other configuration is provided, reasonable defaults are used. The customisation options are shown below with their default values. (*It is not necessary to provide these default values in your configuration file.*)

Set the scale and print resolution of the map as follows. 300-400 pixels-per-inch (ppi) is probably optimal for most maps; 300 ppi give a resolution of about 2.1 metres per pixel at 1:25000. Going beyond 400 ppi will not yield any more detail, and will slow the downloads and blow out the megapixel count considerably. (The size of map features mostly scales with ppi but not with the map scale.)

    scale: 25000              # desired map scale (1:25000 in this case)
    ppi: 300                  # print resolution in pixels per inch

Set the map rotation angle as an angle between +/- 45 degrees anticlockwise from true north (e.g. for a rotation angle of 20, true north on the map will be 20 degrees to the right of vertical). If a non-zero map rotation is used, there will be a slight degradation in quality, however the output at 300+ ppi will still be good. The special value `magnetic` will cause the map to be aligned with magnetic north.

    rotation: 0               # angle of rotation of map (or `magnetic` to align with magnetic north)

Another special value for rotation is `auto`, available when the bounds is specified as a .gpx or .km file. In this case, a rotation angle will be automatically calculated to minimise the map area. This is useful when mapping an elongated region which lies oblique to the cardinal directions.

    rotation: auto            # rotate the map so as to minimise map area

Set the filename for the output map and related files.

    name: map                 # filename to use for the final map image(s) and related georeferencing files

Specify the contour spacing. The standard contour coverage is 10m for eastern NSW and 20m for central and western NSW (and most of the Snowy Mountains, disappointingly). If you specify a 10m interval but only get 20m intervals, this means 10m contour data does not exist in the map area. Large scale contour data (source: 2) at 1m or 2m intervals is sometimes available but seems limited to towns and coastal areas; whilst appearing attractive, it is probably not of much use since the contours are not well-matched with the watercourses.

    contours:
      interval: 10            # contour interval in metres
      index: 100              # index contour interval in metres
      labels: 50              # interval in metres for contour labels
      source: 1               # elevation capture program: 1 for medium scale (1:25000 - 1:100000);
                              # 2 for large scale (1:1000 - 1:10000); 4 for contours derived from DEM.

Specify spacing for the magnetic declination lines. This layer is automatically produced, using a magnetic declination angle for the map centre which is automatically retrieved from the Geoscience Australia website. (Override by specifying an `angle: ` value.) Marking magnetic declination is only really useful on a rogaining map.

    declination:
      spacing: 1000           # perpendicular spacing of magnetic declination lines in metres

Specify UTM grid intervals and appearance. You should include the UTM grid if the map is for normal use. For a rogaining map, the UTM is not needed and clutters up the map, so leave it out.

    grid:
      intervals:              # horizontal and vertical spacing of UTM grid lines in metres
        - 1000                # (East-West grid spacing in metres)
        - 1000                # (North-South grid spacing in metres)
      fontsize: 6.0           # font size of UTM grid labels
      family: Arial Narrow    # font family of UTM grid labels
      weight: 200             # font weight of UTM grid labels

Shaded relief and elevation layers are automatically produced from the ASTER digital elevation model. Shaded relief layers are generated using any azimuthal angles you specify.
  
    relief:
      azimuth:                # azimuth angle for shaded relief layers (degrees clockwise from North)
        - 315                 # (315 degrees is the standard shaded relief angle)
        - 45                  # (each azimuthal angle produces a separate shaded relief layer)
      altitude: 45            # angle of illumination from horizon (45 is standard)
      exaggeration: 1         # vertical exaggeration factor

Drop a control waypoints file (in .gpx or .kml format) into the directory and layers containing control circles and numbers will be automatically generated. If a waypoint is name 'HH' it will be drawn as a triangle, otherwise a circle will be drawn. If a control has 'W' after its number (e.g. '74W'), or separate waypoints marked 'W1', 'W2' etc are found, those waypoints will be represented as water drops.

    controls:
      file: controls.gpx      # filename (.gpx or .kml format) of control waypoint file
      fontsize: 14            # font size for control numbers
      diameter: 7.0           # diameter of control circles in millimetres
      thickness: 0.2          # thickness of control circles in millimetres
      waterdrop-size: 4.5     # size of waterdrop icon in millimetres

Specify the format(s) of the output map files you would like to create. Choose as many of `png`, `tif`, `gif`, `bmp`, `pdf`, `psd` and `layered.tif` as you need. TIFFs will be automatically georeferenced with geotiff tags for use with GIS software. If you specify PNG/GIF/BMP format, a `.map` file will be automatically generated for use with OziExplorer.

    formats:
      - png                   # (default map output is in PNG and multi-layered TIFF format)
      - layered.tif

Specify which layers to exclude from your map. This will prevent downloading of the layers and their inclusion in the final map. List each layer individually. Use the shortcuts `utm`, `aerial` and `relief` to exclude all UTM grid layers, aerial imagery layers and shaded relief/elevation layers, respectively.

    exclude:
      - utm                   # (exclude UTM grid in favour of declination lines)
      - aerial-lpi-sydney     # (exclude hi-resolution sydney aerial imagery)
      - aerial-lpi-towns      # (exclude aerial imagery of towns and regional centres)

Specify colours for individual topographic layers. Each colour should be specified as one of a recognised colour name (e.g. Red, Dark Magenta, Royal Blue), a quoted hex triplet (e.g. '#00FF00', '#2020e0', '#0033ff') or a decimal triplet (e.g. rgb(0,0,255), rgb(127,127,0)). The default color scheme closely matches the current 2nd-edition 25k NSW map sheets (except with brown contours, which I prefer).

    colours:
      contours: '#9c3026'             # brown for contours
      watercourses: '#0033ff'         # blue for watercourses
      sand: '#ff6600'                 # red-brown for sand
      tracks-4wd: 'Dark Orange'       # dark orange for 4wd tracks
      tracks-vehicular: 'Dark Orange' # dark orange for vehicular tracs
      roads-unsealed: 'Dark Orange'   # dark orange for unsealed roads
      roads-sealed: 'Red'             # red for sealed roads
                                      # etc. etc.

(N.B. If a photoshop (psd) file is being produced, do not use pure greyscale colours, as an ImageMagick bug will produce will produce a faulty layer in this case. Instead substitute a slight colour hue, e.g. #000001 instead of black, #808081 instead of middle-grey.)

You can specify your own tiled pattern fills for various area layers if you really want to. Some of the default patterns are shown below. (You might be better off doing this in Photoshop, however.)

    patterns:
      sand:                   # a diagonal dot pattern for sand
        01,10,01,00,00,00
        10,50,10,00,00,00
        01,10,01,00,00,00
        00,00,00,01,10,01
        00,00,00,10,50,10
        00,00,00,01,10,01
      orchards-plantations:   # a checker-board pattern for orchards, vineyards etc.
        111110000
        111110000
        111110000
        111110000
        111110000
        000000000
        000000000
        000000000
        000000000

Finally, specify any layers which you would like to be lifted slightly with a 'glow' effect. This is simply a slight glow behind the label text to enhance its contrast against the map beneath. (By default, glow is applied to labels, UTM eastings and UTM northings.) The default glow effect should be sufficient in most cases.

    glow:
      labels: true      # specify 'true' to apply the default glow (white, 80% strength, 0.2mm thick) ...
      utm-55-eastings:     # ... or you can override the colour, strength and/or size individually
        colour: white   # white-coloured glow
        amount: 100     # 100% strength
        radius: 0.2     # 0.2mm thickness

Georeferencing
==============

The map projection used is transverse mercator, with a central meridian corresponding to the map's centre. This conformal projection is ideal for topographic maps. A grid for the relevant UTM zone(s) (usually zone 55 or 56) can be added to the map (for use with a GPS) by including the UTM grid layers. All output layers (including the aerial imagery and shaded relief layers) are precisely aligned and in the same projection.

An associated world file (.wld) and proj4 projection file (.prj) are produced for the map. If you use Photoshop or GIMP to manually edit your map, the georeferencing tags will be lost. You can use these files and the `geotifcp` command to georeference your final map as a GeoTIFF (do not crop your image at all):

    geotifcp -e map.wld -4 map.prj your-edited-map.tif your-georeferenced-map.tif

If you choose `png`, `gif` or `bmp` as an output format, a .map file will also be produced for use with OziExplorer. (Note that if you move the map image to a different location, you may need to edit the .map file to reflect that new location.)

Layer Descriptions
==================

## Topographic Layers

These are the primary topographic features and cover all of NSW and the ACT. The data is the same as is used in the printed NSW topo series; however a key advantage is that they will likely include newer features (firetrails in particular) not present on the printed maps.

* vegetation: the base vegetation layer representing dense- and medium-crown forest; not particularly good quality and I recommend replacing this layer with one of your own, derived from an aerial imagery layer
* labels: contains labels for all roads, watercourse, contours, homesteads etc in black; these are all combined in one layer so as to avoid overlap of labels
* contours: regular and index contours (also contains hashed depression contours, if any exist), in brown
* ancillary-contours: any ancillary contours that may exist, in dashed brown
* watercourses: watercourse lines, with single-pixel lines representing intermittent watercourses and thicker lines representing perennial watercourses, in blue
* water-areas: areas of water in rivers, lakes and larger dams, in light blue
* water-area-boundaries: boundaries of water areas, in blue
* water-areas-intermittent: intermittent or mostly-dry water areas, in dotted light blue
* water-areas-intermittent-boundaries: boundaries of intermittent or mostly-dry water areas, in blue
* dams: smaller farm dams and other small water points, represented as blue squares
* water-tanks: water tanks, represented as light blue circles
* ocean: ocean areas, in light blue
* coastline: ocean boundary, in black
* roads-sealed: sealed roads, represented as red lines with thicker lines for distributor and arterial roads
* roads-unsealed: unsealed roads, represented as orange lines
* tracks-vehicular: unsealed vehicular tracks, represented as orange dashed lines
* tracks-4wd: 4wd tracks, represented as smaller  orange dashed lines
* pathways: various walking tracks, represented as thinner black dashed lines
* bridges: road and train bridges, in black
* culverts: road sections across culverts, in dark brown
* floodways: road sections across floodways, in blue
* buildings: single buildings (e.g. homesteads), respresented as black squares
* intertidal: intertidal areas, in dotted blue
* inundation: land subject to inundation, in broken horizontal cyan lines
* reef: reef areas, in a cyan hash pattern
* rock-area: coastal and inland rock areas, in a light grey pattern
* sand: sand along rivers and beaches, in dotted brown pattern
* swamp-wet: wet swampy land, in cyan swamp pattern
* swamp-dry: dry swampy land, in brown swamp pattern
* cliffs: cliff sections, in grey bands
* clifftops: tops of said cliffs, as dotted pink line
* excavation: quarry faces, etc, as dotted grey line
* built-up-areas: urban/residential areas, represented in light yellow
* pine: pine plantations, represented in dark green pine pattern
* orchards-plantations: orchards, vineyards and non-pine forest plantation, represented in green tile pattern
* building-areas: larger building complexes (e.g. shopping centres), represented in dark grey
* dam-batters: the inclined portions of some dam walls
* dam-walls: constructed dam walls, represented in black
* cable-ways: chairlifts and cable cars, respresented as solid or dash-dotted black lines respectively
* misc-perimeters: miscellaneous perimeters dividing different land use, represented as thin dashed grey lines
* markers: symbols for caves (open circles), rocks & pinnacles (stars), towers (squares), mines & quarries (mining icons), yards (open squares), windmills (crosses), lighthouses & beacons (beacon icons), lookouts (open circles), campgrounds (tent icon), grids and gates (open circles with one and two bars, respectively); rendered in black
* railways: heavy- and light-gauge railway lines, represented as black hashed lines
* pipelines: water or other pipelines, represented as thin cyan lines
* transmission-lines: high voltage electrical transmission lines, represented as black dot-dash lines
* landing-grounds: landing strips as found on farms, etc, represented as dark grey lines
* wharves: wharves, jetties & boat ramps, represented as black lines
* cadastre: NSW cadastral lines (property boundaries), represented as thin, light grey lines; does not include ACT cadastre which is at present unavailable
* trig-points: trigonometric survey stations, represented as small black icons; not all trig points are present

## Aerial Imagery

These are orthographic aerial images for the specified map area, derived from Google Maps, Nokia Maps, and the NSW LPI department. Depending on your map location there may be up to four different aerial images available.

These layers are very useful for confirming the accuracy of the topographic features. For example, you may be able to manually add firetrails, new dams, etc, which are missing from the NSW map layers, on the basis of what you can see in the aerial imagery. Since the images are correctly georeferenced, this is achieved simply by tracing out the extra information on the appropriate layer while viewing the aerial imagery underneath.

The other excellent use for these aerial imagery layers is to produce your own vegetation layer for a rogaine map. This can be accomplished using the 'color range' selection tool in Photoshop, for example, or other similar selection tools. (If you're feeling adventurous you can even try extracting a vegetation texture from the aerial image to emboss into your vegetation layer, imparting some lift to the map.) You can also create additional vegetation layers (e.g. for the distinctive, nasty heath that sometimes appears in ACT rogaines) using the aerial imagery.

Keep in mind that these aerial images have been warped into an orthographic projection from their original perspective, and may not always be pixel-perfect in alignment across the map area. They are still pretty good however, since we are typically in the 2 metre-per-pixel realm.

* aerial-lpi-ads40: the best, most recent high resolution imagery available from the NSW LPI; available for many but not all areas of interest
* aerial-lpi-sydney: high resolution imagery for the sydney area
* aerial-lpi-towns: medium-high resolution imagery for regional centres
* aerial-lpi-eastcoast: medium resolution imagery for most of the 25k topographic coverage; quite old film imagery (from the 90s?)
* aerial-google: generally good quality, recent aerial imagery from Google Maps; limited to 250 tiles per six hour period
* aerial-nokia: reasonable quality aerial imagery from Nokia Maps; limited to 250 tiles per six hours; georeferencing is not always the best and usually requires some manual nudging for best alignment

## Reference Topographic Layer

This layer (reference-topo) contains the low-resolution topographic map image available from the [SIX viewer](http://lite.maps.nsw.gov.au). This map's poor resolution (175 ppi?) and bad JPEG artifacts make it unsuited to printing, however it is useful to have as a reference for comparison against the output of this software.

## Annotation Layers

* utm-XX-grid: represents a UTM grid for zone XX (zone or zones determined by map bounds)
* utm-XX-eastings: annotates UTM eastings for zone XX across the middle of the map
* utm-XX-northings: annotates UTM northings for zone XX down the middle of the map
* declination: represents lines of magnetic declination for map area
* control-numbers: represents control circles for rogaine courses
* control-circles: represents control numbers for rogaine courses
* waterdrops: icons representing water drops for rogaine courses

## Elevation Layers

These are greyscale images giving elevation and shaded-relief depictions for the map terrain. They are derived from the global ASTER digital elevation model (DEM), which has a resolution of about 45 metres per pixel.

* elevation: a linear greyscale image, with the lowest parts of the map in black and the highest parts in white
* shaded-relief-315, shaded-relief-45, etc: shaded relief renderings for the map's terrain, using the azimuthal angles and terrain exaggeration specified in the configuration file; the number in the file corresponds to the azimuthal angle

These layers can be used as a starting point for various relief shading techniques. These can be used to render a subtle three-dimensional feel to the map and can help the map reader intuitively assess the terrain being represented. (I would love to see rogaine maps with relief shading effects employed!) For further reading, see [shadedrelief.com](http://www.shadedrelief.com/) and [reliefshading.com](http://www.reliefshading.com/).

Shortcomings
============

A few shortcomings are sometimes evident in the generated map images. These can often be fixed by manually adjusting the relevant layer in Photoshop.

* Feature labels sometimes conflict with other features on the map, or are more numerous than needed. This is easily fixed in a multi-layer file by manually moving or deleting the offending label.
* Data is not always complete or accurate. Since the map data represents the current contents of the NSW geospatial database, it reflects any errors the database contains. Aerial imagery may be helpful in identifying any such inaccuracies, which can subsequently corrected manually in the appropriate layer. Examples of inaccuracies I've observed include:
  * the trig points layer depicts some extra points compared to the printed maps, and missed some others;
  * new dams on farms may not always be shown;
  * cliff areas are not always accurately located;
  * the difference between vehicular and 4WD tracks is sometimes debatable; and
  * firetrails and walking paths are sometimes absent or out-of-date.
* Some classes of map data are not currently accessible through the NSW map servers, and are therefore missing from the map. These include:
  * spot heights
  * labels for some geographic features including summits and saddles.
  * boundaries of NSW parks and reserves
  * ancillary hydrographic features including waterfalls
  * relative heights of cliffs
  * points of interest
  * cadastral lines in the ACT
* I have left out a number of obscure man-made features that are unlikely to be found in bush and rural areas of interest.
* For the time being, if you need a legend you'll need to create it manually.
* When rotating the map using the `rotation` parameter, the image quality is reduced slightly. (Since the map servers are only able to render maps in north-up orientation, the images must are subsequently rotated, causing some resampling degradation.) Download and construction of the map will also take longer due to the rotation.
* Not all horizontal labels remain horizontal when a map rotation is specified.
* The various map servers cause problems from time to time. For example: the NSW topographic server has a daily maintenance window at around 10pm AEST for a few minutes, and at other times the servers go down for longer periods (e.g. for a week, one time); the NASA OneEarth server (providing elevation data for shaded relief) is sometimes slow; the LPI aerial imagery server sometimes return no data. This is frustrating. Interrupt the script using ctrl-c, wait a few minutes, then try again. Alternately, exclude the relevant layers from your map configuration if you don't want them.
* There is no guarantee that the NSW ArcIMS servers will continue to function in the future!

Release History
===============

* 12/12/2011: version 0.1 (initial release)
  * 13/12/2011: version 0.1.1: added bridges, floodways, fixed narrow gaps in roads
  * 14/12/2011: version 0.1.2: reworked UTM grid to display correctly across zone boundaries
* 21/12/2011: version 0.2: added map rotation; added specification of map bounds via gpx/kml file; added ability to auto-rotate map to minimise area.
* HEAD: misc. additions (e.g. lookouts, campgrounds, rock/pinnacle labels, etc); collected point markers into single layer; separated permanent and intermittent water layers; prevented label/feature overlap; decreased download times; removed unavailable ACT layers; added low-res reference topo.

