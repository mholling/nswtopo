# NSW Topo Maps Templates

Sample configuration file for each 1:25k NSW topo map. Template includes

- nsw/topographic layer
- intuitive shaded-relief depiction
- UTM grid

# How to Use the Templates

Select a map of your choice and replace (copy over) default `nswtopo.cfg`. Optionally, tweak the configuration file to suit your needs. The last step is to run `nswtopo.rb` as usuall.

Map output is SVG file (default) nad output file name is same as map name. For example, `89301S-katoomba.cfg` creates `89301S-katoomba.svg` map.

Program generated files, such as `nsw.topographic.json` and `relief.tif` (or any other) should be deleted between subsequent runs.