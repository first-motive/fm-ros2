cmake_minimum_required(VERSION 3.8)
project(fm_control)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(trajectory_msgs REQUIRED)
find_package(unitree_hg REQUIRED)

add_executable(control_node src/control_node.cpp)
target_include_directories(control_node PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(control_node PUBLIC cxx_std_17)
ament_target_dependencies(control_node rclcpp)

# G1-D right-arm Servo -> arm_sdk bridge (the `real` backend; replaces ros2_control).
add_executable(g1_arm_sdk_bridge src/g1_arm_sdk_bridge.cpp)
target_include_directories(g1_arm_sdk_bridge PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_compile_features(g1_arm_sdk_bridge PUBLIC cxx_std_17)
ament_target_dependencies(g1_arm_sdk_bridge rclcpp trajectory_msgs unitree_hg)

install(TARGETS control_node g1_arm_sdk_bridge DESTINATION lib/${PROJECT_NAME})
install(DIRECTORY include/ DESTINATION include)

# Backend-selectable ros2_control xacro consumed by the sim/teleop launches.
install(DIRECTORY urdf DESTINATION share/${PROJECT_NAME})

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()

  find_package(ament_cmake_gtest REQUIRED)
  ament_add_gtest(test_g1_arm_sdk_bridge test/test_g1_arm_sdk_bridge.cpp)
  target_include_directories(test_g1_arm_sdk_bridge PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include)
  ament_target_dependencies(test_g1_arm_sdk_bridge unitree_hg)
endif()

ament_package()
