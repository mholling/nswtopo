# Description

Once you've added your layers, use the *render* command to create the map itself. Different output formats are available for various purposes. In its simplest form, to render a GeoTIFF from a map file:

```
$ nswtopo render map.tgz map.tif
```

Specify your output format either as a filename with appropriate extension, or just the format extension itself (in which case the map's file name will be used). You can create multiple outputs at once.

Depending on contents, creation of the map may take some time, particularly in the labelling step.

# Formats

The following formats are available:

* **svg**: the native vector format - viewable with modern web browsers and editable by *Inkscape*, *Adobe Illustrator* or a text editor
* **tif**: a standard raster format, including *GeoTIFF* metadata tags for georeferencing
* **pdf**: *Portable Document Format*, either in the original vector form, or as a raster by setting a resolution with `--ppi`
* **kmz**: for use with *Google Earth* (add as a network link for best results)
* **zip**: a tiled format used by the *Avenza Maps* mobile app
* **mbtiles**: a tiled format for use with mobile GPS apps including *Locus Map* and *OruxMaps*
* **gemf**: a fast tiled format compatible with *Locus Map*
* **svgz**: a compressed SVG format, viewable directly in some browsers
* **png**: the well-known *Portable Network Graphics* format
* **jpg**: the well-known *JPEG* format (not well-suited to maps)

# Output Resolution

Most of the output formats are *raster* (pixel-based) formats. Use the `--ppi` option to set a resolution for these formats, in pixels per inch (PPI). The choice of PPI is a tradeoff between image quality and file size. The default value of 300 is a good choice for most purposes. Consider a higher PPI when producing a map for printing.

For the *mbtiles* format, resolution values are fixed to zoom levels. The default maximum zoom level of 16 corresponds to around 260 PPI.

# Setting Up Chrome

You'll need to have *Google Chrome* or *Chromium* installed. The Chrome browser is used by *nswtopo* in headless mode to measure font metrics during labelling, and to render the vector SVG format as a raster graphic or PDF. Chrome should be detected automatically, but you can also configure its path manually if necessary:

```
$ nswtopo config --chrome "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
```

# Miscellaneous

After generating your map in SVG format, you can add content outside of *nswtopo* using a vector graphics editor such as Inkscape. You can then generate raster formats from the edited SVG instead of the map file:

```
$ nswtopo render map.svg map.tif
```

Maps normally use a white background. To specify a different background colour, use the `--background` option.

For raster formats, use the `--dither` option to create the raster in indexed colour mode. This can reduce file size. For best results, have the `pngquant` program available on your command line for the dithering process.
