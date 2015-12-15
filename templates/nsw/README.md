NSW Topo Map Templates
======================

Sample configuration file for each 1:25k NSW topo map. Templates include:

- nsw/topographic layer
- intuitive shaded-relief depiction
- UTM grid

An index for the map sheets can be examined [here](http://www.arcgis.com/home/webmap/viewer.html?url=http://maps.six.nsw.gov.au/arcgis/rest/services/sixmaps/Boundaries/MapServer?layers=show:18).

## How to Use the Templates

Select a map of your choice and copy its `.cfg` file into a new folder as `nswtopo.cfg`. Optionally, tweak the configuration file to suit your needs. The last step is to run `nswtopo.rb` as usual.

Map output is SVG file (default) and output file name is same as map name. For example, `8930-1S-katoomba.cfg` creates `8930-1S-katoomba.svg` map.
