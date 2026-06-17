from setuptools import find_packages, setup

package_name = "fm_data_dataset"

setup(
    name=package_name,
    version="0.0.0",
    packages=find_packages(exclude=["test"]),
    data_files=[
        ("share/ament_index/resource_index/packages", ["resource/" + package_name]),
        ("share/" + package_name, ["package.xml"]),
    ],
    install_requires=["setuptools"],
    zip_safe=True,
    maintainer="First Motive",
    maintainer_email="nish@ubundi.co.za",
    description="First Motive data engine: manage, replay, and push datasets to HF hub",
    license="Apache-2.0",
    tests_require=["pytest"],
    entry_points={
        "console_scripts": [
            "dataset_manager = fm_data_dataset.dataset_manager:main",
        ],
    },
)
