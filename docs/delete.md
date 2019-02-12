# Description

Use the *delete* command to delete layers from the map. Specify the name of the layer or layers you wish to delete:

```
$ nswtopo delete map.tgz nsw.relief grid
```

When deleting multiple layers, a form of wildcard is also available:

```
$ nswtopo delete map.tgz "nsw.topographic.*"
```

Use the *info* command to see the names of layers currently in the map file.
