# Description

Configure and view permanent *nswtopo* settings using the *config* command. For example, to set the *Google Chrome* path for rendering maps:

```
$ nswtopo config --chrome "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
nswtopo: configuration updated
```

To set the path for a vegetation dataset:

```
$ nswtopo config --path ~/SPOT5/s5hgps_nsw_y20082012_bcvl0.tif nsw.vegetation-spot5
nswtopo: configuration updated
```

To review your current configuration:

```
$ nswtopo config
chrome: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
nsw.vegetation-spot5:
  path: "/Users/matthew/SPOT5/s5hgps_nsw_y20082012_bcvl0.tif"
```
