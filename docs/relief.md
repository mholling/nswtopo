# Description

The *relief* command generates shaded relief from a Digital Elevation Model (DEM). You can use any DEM in a planar projection, but a resolution of 30 metres or better is suggested.

# Obtaining the DEM
Use the *ELVIS* website [http://elevation.fsdf.org.au] to download DEM tiles for any NSW location. The NSW 2-metre and 5-metre tiles are ideal. 1-metre NSW and ACT tiles also work but are more detailed than necessary. (Do not download Geoscience Australia tiles or point-cloud data.)

DEM tiles from the ELVIS website are delivered as doubly-zipped files. It's not necessary to unzip the download, although unzipping the first level to a folder will improve processing time.

# Configuration

No configuration is needed to get good results from ELVIS data. Use the following options to adjust the layer's appearance, if desired:

* **resolution**: resolution for the DEM data; a lower value will reduce file size but yields a smoother effect
* **opacity**: overall layer opacity
* **altitude**: raking angle of the light from the horizon
* **azimuth**: azimuth angle of the light, clockwise from north; deviation from the 315° default can be counter-intuitive
* **sources**: number of light sources to use for multi-directional shading
* **yellow**: amount of yellow illumination to apply as a fraction of grey shading
* **factor**: vertical exaggeration factor

Opacity and exaggeration can both be used to adjust the subtly of the shading effect.
