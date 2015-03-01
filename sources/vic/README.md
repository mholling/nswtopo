VIC Map Layers
==============

This directory contains map layers specific to Victoria.

## Topographic

This topographic map is derived from a few VIC government servers, however the feature set is incomplete. All the basic topographic features are represented, including elevation, hydrographic and transport features. Watercourses and mountains are labelled, however other natural features remain unlabeled. Other notably missing features include building points, building areas and urban areas. Include it in your map layer list as follows:

    include:
    - vic/topographic

## Vegetation

Include the `vic/vegetation` layer to include a layer representing tree cover. Three different levels of cover, *DENSE*, *MEDIUM* and *SCATTERED*, are represented as varying shades of green.
