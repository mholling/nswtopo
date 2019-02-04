# Description

Once you've added your layers, use the *render* command to create the map itself. Different output formats are available for various purposes.

Specify your output format either as a filename with appropriate extension, or just the format extension itself (in which case the map's file name will be used). You can create multiple outputs at once.

Depending on contents, creation of the map may take some time, particularly in the labelling step.

# Formats

The following formats are available:

* **svg**: the native vector format - viewable with modern web browsers and editable by *Inkscape*, *Adobe Illustrator* or a text editor
* **tif**: a standard raster format, including *GeoTIFF* metadata tags for georeferencing
* **pdf**: *Portable Document Format*, either in the original vector form, or as a raster by setting a resolution with `--ppi`
* **kmz**: for use with *Google Earth* (add as a network link for best results)
* **zip**: a tiled format used by the *Avenza Maps* mobile app
* **mbtiles**: a tiled format for use with mobile GPS apps including *Locus Map* and *Guru Maps*
* **svgz**: a compressed SVG format, viewable directly in some browsers
* **png**: the well-known *Portable Network Graphics* format
* **jpg**: the well-known *JPEG* format (not well-suited to maps)

# Output Resolution

Most of the output formats are *raster* (pixel-based) formats. Use the `--ppi` option to set a resolution for these formats, in pixels per inch (PPI). The choice of PPI is a tradeoff between image quality and file size. The default value of 300 is a good choice for most purposes. Consider a higher PPI when producing a map for printing.

For the *mbtiles* format, resolution values are fixed to zoom levels. The default maximum zoom level of 16 corresponds to around 260 PPI.

# Setting Up Chrome

To create any output format except SVG, you'll need to have *Google Chrome* installed. Chrome is used by *nswtopo* in headless mode to render the vector SVG format as a raster graphic. *Firefox* can also be used, although it does not render some effects correctly. (On MacOS and Linux, Chrome is also used to measure font metrics during labelling.)

Add the path for your Chrome executable to your *nswtopo* configuration as follows:

```
$ nswtopo config --chrome "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
```

# Miscellaneous

For raster formats, use the `--dither` option to create the raster in indexed colour mode. This can reduce file size. For best results, have the `pngquant` program available on your command line for the dithering process.

After generating your map in SVG format, you can add content outside of *nswtopo* using a vector graphics editor such as Inkscape. Use the `--external` option to render from the edited map, instead of the internal copy maintained by *nswtopo*.
