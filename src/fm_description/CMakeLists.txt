cmake_minimum_required(VERSION 3.8)
project(fm_description)

find_package(ament_cmake REQUIRED)

install(
  DIRECTORY urdf meshes launch
  DESTINATION share/${PROJECT_NAME}
)

# Vendor the Unitree G1 descriptions into this package's share so their meshes
# resolve as package://fm_description/<dir>/... — the only mesh scheme Foxglove
# Studio fetches through foxglove_bridge (file:// is host-scoped and fails over a
# bridge). Sourced from the vcs-imported unitree_ros working copy (src/external/,
# gitignored), so present only after import-externals.sh. Guarded so a clean
# checkout (e.g. CI without externals) still builds.
#   g1_d_description   the wheeled G1-D (AGV base + arms) — the default view
#   g1_description     the bipedal 29 DOF reference body
set(UNITREE_ROBOTS "${CMAKE_CURRENT_SOURCE_DIR}/../external/unitree_ros/robots")
foreach(desc g1_d_description g1_description)
  if(EXISTS "${UNITREE_ROBOTS}/${desc}/meshes")
    install(DIRECTORY "${UNITREE_ROBOTS}/${desc}" DESTINATION share/${PROJECT_NAME})
    message(STATUS "fm_description: vendoring ${desc} from ${UNITREE_ROBOTS}")
  else()
    message(WARNING
      "fm_description: ${desc} not found under ${UNITREE_ROBOTS} — run "
      "./scripts/import-externals.sh before building to view the G1.")
  endif()
endforeach()

# Vendor the LeRobot SO101 arm into this package's share as so101_description so
# its meshes resolve as package://fm_description/so101_description/assets/... —
# the only mesh scheme Foxglove Studio fetches through foxglove_bridge. The
# SO101 upstream ships as plain files (flat so101_new_calib.urdf + assets/*.stl),
# vendored from the vcs-imported SO-ARM100 working copy. vcs names the dir after
# its external.repos key (so_arm), not the repo, so the source lives at
# src/external/so_arm/ (gitignored), present only after import-externals.sh. The
# trailing slash on the source installs its contents (URDF + assets/) into
# so101_description. Guarded so a clean checkout (e.g. CI without externals) still builds.
set(SO101_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../external/so_arm/Simulation/SO101")
if(EXISTS "${SO101_SRC}/assets")
  install(DIRECTORY "${SO101_SRC}/" DESTINATION share/${PROJECT_NAME}/so101_description)
  message(STATUS "fm_description: vendoring so101_description from ${SO101_SRC}")
else()
  message(WARNING
    "fm_description: SO101 not found under ${SO101_SRC} — run "
    "./scripts/import-externals.sh before building to view the SO101.")
endif()

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()
endif()

ament_package()
