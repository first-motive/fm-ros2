# fm_vlta

Data engine. Metapackage grouping the VLTA sub-packages. Split-ready: this whole
group extracts cleanly into its own repo later.

## Sub-packages

```
fm_vlta_record  -> record episodes to LeRobot format
fm_vlta_dataset -> manage / replay / push datasets to HF hub
fm_vlta_train   -> training (may move to cloud)
fm_vlta_serve   -> inference -> orchestration
```

## Build type

`ament_cmake` metapackage (exec-depends on the four sub-packages).
