# fm_policy

Policy layer: how a task is learned and served, model-agnostic. Metapackage
grouping the training and serving sub-packages. Split-ready: this whole group
extracts cleanly into its own repo later.

## Sub-Packages

```
fm_policy_train -> model training (may move to cloud)
fm_policy_serve -> model inference serving
```

## Build Type

`ament_cmake` metapackage (exec-depends on the two sub-packages).
