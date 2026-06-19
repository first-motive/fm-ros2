# fm_data

Data engine: how episodes are captured and curated. Metapackage grouping the
capture and dataset sub-packages. Split-ready: this whole group extracts cleanly
into its own repo later.

## Sub-Packages

```
fm_data_record  -> record episodes to LeRobot format
fm_data_dataset -> manage / replay / push datasets to HF hub
```

## Build Type

`ament_cmake` metapackage (exec-depends on the two sub-packages).
