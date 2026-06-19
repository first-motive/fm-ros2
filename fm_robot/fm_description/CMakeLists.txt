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
# bridge). Sourced from the vcs-imported unitree_ros working copy (external/,
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
# external/so_arm/ (gitignored), present only after import-externals.sh. The
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

# Vendor the Enactic OpenArm VISUAL meshes into this package's share as STL,
# resolving as package://fm_description/openarm_meshes/... — the scheme Foxglove
# Studio fetches through foxglove_bridge. Unlike the G1/SO101 flat-file vendoring,
# OpenArm ships as a built ament_cmake package; only its visual meshes are
# converted here. The upstream visual meshes are COLLADA (.dae) with mixed declared
# up-axes (arm + pinch gripper Y_UP, body Z_UP). Foxglove ignores per-file up_axis
# and applies one global mesh-up setting, so the raw .dae meshes render mis-rotated
# (RViz honours up_axis, so it is unaffected). assimp bakes each file's up_axis into
# the geometry on export, so a plain DAE -> STL conversion yields the orientation
# RViz already presents — no extra rotation. Source is the vcs-imported working copy
# (external/openarm_description, gitignored). Guarded so a clean checkout
# (e.g. CI without externals) still builds.
set(OPENARM_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../external/openarm_description")
set(OPENARM_MESH_OUT "${CMAKE_CURRENT_BINARY_DIR}/openarm_meshes")
if(EXISTS "${OPENARM_SRC}/assets")
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  find_program(ASSIMP_EXE assimp)
  if(NOT ASSIMP_EXE)
    message(WARNING
      "fm_description: assimp CLI not found — OpenArm visual meshes not "
      "converted. Rebuild the dev image (it installs assimp-utils) to view the "
      "OpenArm.")
  else()
    # Enumerate the visual .dae sources and the .stl outputs they map to, mirroring
    # the converter's rule (src "*/visual/*.dae" -> out "<rel>.stl"). Declaring the
    # real .stl files as add_custom_command OUTPUTs (not a directory BYPRODUCT) lets
    # CMake track them individually: it reruns the convert whenever an .stl is
    # missing or its .dae/the script is newer. A bare custom target could not detect
    # a deleted output, so a wiped build/ left dangling install symlinks that never
    # regenerated. CONFIGURE_DEPENDS re-globs when the source set changes.
    file(GLOB_RECURSE OPENARM_DAE_ALL CONFIGURE_DEPENDS "${OPENARM_SRC}/*.dae")
    set(OPENARM_DAE "")
    set(OPENARM_STL "")
    foreach(dae ${OPENARM_DAE_ALL})
      if(dae MATCHES "/visual/")
        file(RELATIVE_PATH rel "${OPENARM_SRC}" "${dae}")
        string(REGEX REPLACE "\\.dae$" ".stl" rel_stl "${rel}")
        list(APPEND OPENARM_DAE "${dae}")
        list(APPEND OPENARM_STL "${OPENARM_MESH_OUT}/${rel_stl}")
      endif()
    endforeach()

    if(OPENARM_STL)
      # The converter is idempotent (skips up-to-date meshes), so this is cheap on
      # incremental builds and regenerates only what is missing or stale.
      add_custom_command(
        OUTPUT ${OPENARM_STL}
        COMMAND "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/scripts/convert_openarm_visual_meshes.py"
                --src "${OPENARM_SRC}"
                --out "${OPENARM_MESH_OUT}"
                --assimp "${ASSIMP_EXE}"
        DEPENDS ${OPENARM_DAE}
                "${CMAKE_CURRENT_SOURCE_DIR}/scripts/convert_openarm_visual_meshes.py"
        COMMENT "fm_description: converting OpenArm visual meshes to STL"
        VERBATIM)
      add_custom_target(openarm_meshes ALL DEPENDS ${OPENARM_STL})
      install(DIRECTORY "${OPENARM_MESH_OUT}/"
              DESTINATION share/${PROJECT_NAME}/openarm_meshes)
    else()
      message(WARNING
        "fm_description: no OpenArm visual .dae found under ${OPENARM_SRC} — "
        "meshes not converted.")
    endif()
  endif()
else()
  message(WARNING
    "fm_description: OpenArm not found under ${OPENARM_SRC} — run "
    "./scripts/import-externals.sh before building to view the OpenArm.")
endif()

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()
endif()

ament_package()
