# -*- coding: utf-8 -*-
from setuptools import setup, find_packages

with open("requirements.txt") as f:
    install_requires = f.read().strip().split("\n")

setup(
    name="item_tracking",
    version="0.0.1",
    description="Individual Item Tracking: per-physical-unit identity, QR/barcode, location history.",
    author="erpnextcomp_demo",
    packages=find_packages(),
    zip_safe=False,
    include_package_data=True,
    install_requires=install_requires,
)
