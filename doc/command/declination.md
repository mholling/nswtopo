# Description

Use the *declination* command to add lines of magnetic declination to the map. These are useful primarily in rogaining maps, where they facilitate compass bearings.

# Declination Angle

The magnetic declination angle is obtained from the NOAA online calculator using the World Magnetic Model. An accuracy of ±0.5° is typical. In the event that the calculator is offline, you can provide a declination angle manually using the `--angle` option.

# Appearance

Declination lines are spaced at one-kilometre intervals, or according to the `--spacing` option if passed. Small directional arrows are provided periodically along each line at 160mm intervals.

The `--offset` option shifts the lines along the horizontal, if fine-tuning is required.

Change colour using the `--stroke` option, with an *RGB triplet* (e.g. *800080*) or *web colour* name (e.g. *purple*).
