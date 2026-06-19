# fm_learning (metapackage)

`ament_cmake` metapackage. Exec-depends on the learning sub-groups (data, policy)
so the whole group installs as one unit and stays split-ready.

It lives as a sibling of the children (not their parent directory) because colcon prunes
its crawl at any directory that is itself a package — nesting the children under the
metapackage would hide them from the build.

`fm_data` and `fm_policy` are themselves metapackages with their own sub-packages, so
this group nests three levels deep. See `../README.md` for the learning layer overview.
