cmake_minimum_required(VERSION 3.8)
project(fm_description)

find_package(ament_cmake REQUIRED)

install(
  DIRECTORY urdf meshes launch
  DESTINATION share/${PROJECT_NAME}
)

# Vendor the Unitree G1 description into this package's share so its meshes
# resolve as package://fm_description/g1_description/... — the only mesh scheme
# Foxglove Studio fetches through foxglove_bridge (file:// is host-scoped and
# fails over a bridge). Sourced from the vcs-imported unitree_ros working copy
# (src/external/, gitignored), so it is only present after import-externals.sh.
# Guarded so a clean checkout (e.g. CI without externals) still builds.
set(G1_DESC "${CMAKE_CURRENT_SOURCE_DIR}/../external/unitree_ros/robots/g1_description")
if(EXISTS "${G1_DESC}/meshes")
  install(DIRECTORY "${G1_DESC}" DESTINATION share/${PROJECT_NAME})
  message(STATUS "fm_description: vendoring G1 description from ${G1_DESC}")
else()
  message(WARNING
    "fm_description: G1 description not found at ${G1_DESC} — run "
    "./scripts/import-externals.sh before building to view the G1.")
endif()

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()
endif()

ament_package()
