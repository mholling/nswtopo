# Description

Use the *remove* command to delete layers from the map. Specify the name of the layer or layers you wish to remove:

```
$ nswtopo remove map.tgz nsw.relief grid
```

When removing multiple layers, a form of wildcard is also available:

```
$ nswtopo remove map.tgz "nsw.topographic.*"
```

Use the *info* command to see the names of layers currently in the map file.
