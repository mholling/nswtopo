# nswtopo – Vector Topographic Mapping Tool

### _Version 2.0.0_

This software is a tool for downloading and compiling high-resolution vector topographic maps from internet map servers. Map layers are currently provided for NSW and Tasmanian topographic maps. Maps are produced in [scalable vector graphics](http://en.wikipedia.org/wiki/Scalable_Vector_Graphics) (SVG) format for use and further editing with vector graphics programs such as Inkscape or Illustrator. A number of other raster formats, including GeoTIFF, KMZ, mbtiles and Avenza Maps, can also be produced.

The software was originally designed for the production of rogaining maps and includes several useful features for this purpose (including control checkpoint layers, arbitrary map rotation and magnetic declination marker lines). However the software is also useful for anyone wanting to create custom NSW topo maps for outdoor recreation, particularly on mobile apps.

The *nswtopo* software is written in the Ruby language and runs as a command-line tool. Some familiarity with command-line usage and conventions is helpful.

# Prerequisites

The preferred operating system for *nswtopo* is a Unix-style OS such as Linux or macOS. These systems have conventional command-line interfaces. Operation in Windows is possible but you're more likely to encounter problems, since I do not frequently test the software in a Windows environment.

The following software is required in order to run *nswtopo*:

* The [*Ruby* programming language](https://www.ruby-lang.org). You'll need at least Ruby 2.5.
* The [*GDAL*](https://gdal.org) command-line utilities, version 2.3 or later, for geospatial data processing.
* [*ImageMagick*](https://imagemagick.org), a command-line image manipulation tool.
* The [*Google Chrome*](https://www.google.com/chrome) web browser, for getting font information and rendering your map.

Some optional software helps with additional functionality:

* A zip command utility (either *zip* or *7z*), if you wish to produce *KMZ* maps.
* [*SQLite*](https://sqlite.org), if you need to produce maps in *mbtiles* format.
* [*pngquant*](https://pngquant.org), if you wish to produce indexed colour map images.
* [*Inkscape*](https://inkscape.org), if you wish to make manual edits or additions to your map.

Finally, a geographic viewing or mapping program such as [*Google Earth Pro*](https://www.google.com/earth) is useful for easily defining the area you wish to map, and for viewing your resulting map and other GPS data.

You can check that the required tools are correctly installed by using the following commands:

```sh
$ ruby --version
$ identify -version
$ gdalinfo --version
```

Each program should return version information if it's installed correctly.

## Windows
  * A complete Ruby installation for Windows can be [downloaded here](https://rubyinstaller.org) (be sure to select `Add Ruby executables to your PATH` when installing).
  * Download a pre-built [ImageMagick binary](https://imagemagick.org/script/download.php#windows) for Windows. Be sure to select `add application directory to your system path` and `install legacy utilities` when installing.
  * Install the GDAL utilities using the [OSGeo4W](https://trac.osgeo.org/osgeo4w) installer. Use the `advanced install` option as only the GDAL package is required. When presented with the package list, select `All -> Uninstall` to deselect everything, then open `Commandline Utilites` and choose `Install` for the GDAL package. (Accept the required dependencies on the following page.)
  Make GDAL available on the command line with the following:
    ```sh
    setx PATH "%PATH%;C:\OSGeo4W64\bin"
    setx GDAL_DATA "C:\OSGeo4W64\share\gdal"
    ```
  * (Other ways of obtaining Windows GDAL utilities are listed [here](https://trac.osgeo.org/gdal/wiki/DownloadingGdalBinaries#Windows), but check the minimum version requirement.)
  * Download and install [Google Chrome](https://www.google.com/chrome).
  * If you want to create KMZ maps, install [7-Zip](https://www.7-zip.org) and add its location to your PATH:
    ```sh
    setx PATH "%PATH%;C:\Program Files\7-Zip"
    ```

    **Note**: When using the Windows Command Prompt, I strongly recommend disabling *QuickEdit* mode in the *Properties* window to avoid frustration.

## macOS
  * ImageMagick and GDAL can obtained for macOS by first setting up [MacPorts](https://www.macports.org), a macOS package manager; follow [these instructions](https://guide.macports.org/chunked/installing.html) on the MacPorts site. After MacPorts is installed, use it to install the packages with `sudo port install gdal` and `sudo port install imagemagick`
  * Alternatively, you can download and install pre-built binaries; try [here](http://www.kyngchaos.com/software/frameworks) for GDAL, and the instructions [here](https://imagemagick.org/script/download.php#macosx) for ImageMagick. (This may or may not be quicker/easier than installing XCode and MacPorts!)
  * Type `ruby -v` in a terminal window to see whether a compatible Ruby version already exists. If not, you can install Ruby a number of ways, as explained [here](https://www.ruby-lang.org/en/downloads). (If you are using MacPorts, `sudo port install ruby25 +nosuffix` should also work.)
  * Download and install [Google Chrome](https://www.google.com/chrome).

## Linux

Dependencies should be easy to install on a Linux PC. The appropriate Ruby, ImageMagick and GDAL packages should all be available using your distro's package manager (Pacman, RPM, Aptitude, etc).

# Installation

The easiest way to install the latest *nswtopo* release is with Ruby's built-in *gem* package manager:

```sh
$ gem install nswtopo
```

Verify that the `nswtopo` command is available in your terminal of choice by issuing the following command. You should see the current version number:

```sh
$ nswtopo -v
```

## Installing Layers

Layer definitions are kept in a separate [*nswtopo-layers* repository](https://github.com/mholling/nswtopo-layers), enabling their maintenance independent of the *nswtopo* codebase. Install the layers as follows:

```sh
$ gem install nswtopo-layers
```

Refer to the [repository](https://github.com/mholling/nswtopo-layers) for layer documentation.

## Manual Installation

Installation via ruby gem is not strictly necessary. It's possible use the [git](https://git-scm.com) repositories directly:

```sh
$ git clone https://github.com/mholling/nswtopo.git
```

Add the program to your PATH: in Windows, by [editing the environment variable](https://www.howtogeek.com/118594/how-to-edit-your-system-path-for-easy-command-line-access) in Control Panel; in Linux or macOS, by adding to your home directory's `.profile` file:

```sh
export PATH=/path/to/nswtopo/bin:$PATH
```

Finally, reload your terminal and install the layers:

```sh
$ git clone https://github.com/mholling/nswtopo-layers.git
$ nswtopo config --layer-dir nswtopo-layers/layers
```

# Usage

Interaction with *nswtopo* is significantly revamped for version 2.0. Map data is now stored in a single file. A folder or configuration file is no longer required for each map. Separate commands are used to initialise the map file, add various layers and finally render to an output. Most commands take the following format:

```sh
$ nswtopo <command> [options] <map.tgz> [...]
```

Optional command settings can be given as short and/or long *options* (e.g. `-b` or `--bounds`), some of which take a value. The options you choose determine how the command is run. Commands will run with sensible defaults when no options are selected. Positioning of command options is permissive: you can add them before or after non-option arguments (such as layer names, filenames, etc).

The `map.tgz` argument is the filename of your map file. Any name can be used. The `.tgz` extension is suggested as it reflects the actual file format (a *gzipped tar* archive).

## Help

Help is available from the command line. If a command is issued without arguments, a short usage screen will be displayed as reminder. More detailed help is available using the `--help` option:

```sh
$ nswtopo --help
```

```sh
$ nswtopo <command> --help
```

## Commands

General usage for the *nswtopo* program is [described here](docs). Detailed documentation for each of the available commands is also available:

* [*init*](docs/init.md): initialise map bounds and scale
* [*info*](docs/info.md): display map layers and metadata
* [*add*](docs/add.md): add named map layer
* [*contours*](docs/contours.md): add contours from elevation data
* [*spot-heights*](docs/spot-heights.md): add spot heights from elevation data
* [*relief*](docs/relief.md): add shaded relief
* [*grid*](docs/grid.md): add UTM grid
* [*declination*](docs/declination.md): add magnetic declination lines
* [*controls*](docs/controls.md): add rogaine control markers
* [*overlay*](docs/overlay.md): add KML or GPX overlay
* [*delete*](docs/delete.md): delete map layer
* [*render*](docs/render.md): render map in various formats
* [*layers*](docs/layers.md): list available map layers
* [*config*](docs/config.md): configure nswtopo

# Workflow for Rogaine Setters

The following workflow is suggested to create a rogaine map.

1.  Configure nswtopo, if you haven't already done so. Download and save the 9GB [SPOT5 vegetation data](ftp://qld.auscover.org.au/spot/woody_fpc_extent/nsw-2011/s5hgps_nsw_y20082012_bcvl0.tif) for NSW. Set its location, and that of Google Chrome:

    ```sh
    $ nswtopo config --path /path/to/s5hgps_nsw_y20082012_bcvl0.tif nsw.vegetation-spot5
    $ nswtopo config --chrome "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    ```

1.  Set out the expected bounds of your course using the polygon tool in Google Earth, saving it as `bounds.kml`. Use a partially transparent style to make it easier to see. Configure a new map file with these bounds:

    ```sh
    $ nswtopo init --bounds bounds.kml preliminary.tgz
    ```

1.  Add the base topographic layers and a grid:

    ```sh
    $ nswtopo add preliminary.tgz nsw/vegetation-spot5
    $ nswtopo add preliminary.tgz nsw/topographic
    $ nswtopo grid preliminary.tgz
    ```

1.  Download digital elevation model (DEM) tiles for your area from the [ELVIS](http://elevation.fsdf.org.au/) website. Various DEM resolutions will be available depending on location. Prefer 2m and 5m tiles from NSW, with 1m ACT and NSW tiles if needed. Add contours to your map from this data:

    ```sh
    $ nswtopo contours -i 5 -x 50 --replace nsw.topographic.contours preliminary.tgz DATA_25994.zip
    ```

1.  Create and view your preliminary map:

    ```sh
    $ nswtopo render preliminary.tgz svg tif
    ```

1.  Use the preliminary map to assist you in setting your rogaine. I recommend using a mobile mapping app such as [Avenza Maps](https://www.avenza.com/avenza-maps), [Locus Map](https://www.locusmap.eu) or [Galileo Maps/Guru Maps](https://galileo-app.com). Save in the *tif* or *zip* format for Avenza Maps, or *mbtiles* format for Locus or Guru. During setting, use the app (or a handheld GPS unit) to record waypoints for the locations you flag.

1.  Use Google Earth to finalise your control locations. Name each waypoint with its control number. Add extra waypoints named *HH* (hash house), *W* (water drop) and *ANC* (all-night cafe), as appropriate. Save the waypoints as a `controls.kml` file.

1.  Again in Google Earth, mark out any boundaries and out-of-bounds areas using the polygon tool. Style them as they should appear on your map: I recommend *filled black 30%*. Save the boundaries as a `boundaries.kml` file.

1.  Create a new map with your desired dimensions:

    ```sh
    $ nswtopo init --bounds controls.kml --dimensions 210,297 --rotation magnetic rogaine.tgz
    ```

    If you have trouble fitting your controls to the map sheet, you can use the automatic rotation feature (`--rotation auto`) to minimise the map area.

1.  Add all your layers:

    ```sh
    $ nswtopo add rogaine.tgz nsw/vegetation-spot5
    $ nswtopo add rogaine.tgz nsw/topographic
    $ nswtopo contours -i 5 -x 50 --replace nsw.topographic.contours rogaine.tgz DATA_25994.zip
    $ nswtopo spot-heights --replace nsw.topographic.spot-heights rogaine.tgz DATA_25994.zip
    $ nswtopo overlay rogaine.tgz boundaries.kml
    $ nswtopo relief rogaine.tgz DATA_25994.zip
    $ nswtopo declination rogaine.tgz
    $ nswtopo controls rogaine.tgz controls.kml
    ```

1.  Optionally, you can add any unmarked tracks you've found on the course. Trace them out with Google Earth, or record them with a GPS or phone while setting. Then add them to your map:

    ```sh
    $ nswtopo overlay --stroke "#FF7518" --stroke-width 0.3 --stroke-dasharray 1.8,0.6 rogaine.tgz unmarked.kml
    ```

    (Use the `--simplify` option for tracks recorded with a GPS.)

1.  At this point you will need to render the map before adding peripheral information such as a map title, credits, safety information and control descriptions. There are two ways to do this:

    1.  Render the map to a high-resolution raster and make the edits in a raster graphics editor such as *Photoshop* or [*GIMP*](https://www.gimp.org). First choose a print resolution (say 600 ppi) to render the map in PNG format:

        ```sh
        $ nswtopo render --ppi 600 rogaine.tgz rogaine.png
        ```

        Open the PNG in the graphics editor, then add your information layers there. Export directly (usually in TIFF format) for sending to the printers.

    1.  Keep the map in vector (SVG) format and make your edits in a vector graphics editor such as [*Inkscape*](https://inkscape.org).

        ```sh
        $ nswtopo render rogaine.tgz rogaine.svg
        ```

        After you've added your information layers, save the SVG and use *nswtopo* to render it to the final raster for printing:

        ```sh
        $ nswtopo render --external rogaine.svg --ppi 600 rogaine.tgz rogaine.tif
        ```

    I recommend the first method. Inkscape can be difficult to use. More importantly, it is not SVG standards-compliant, so some errors may be introduced. By using a raster graphics editor, you can be confident in the final appearance of the printed map. If your PC struggles with the image size at 600 ppi, a resolution as low as 300 ppi will still yield satisfactory results.
