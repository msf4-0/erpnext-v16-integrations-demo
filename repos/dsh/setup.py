from setuptools import setup, find_packages

with open("requirements.txt") as f:
    install_requires = f.read().strip().split("\n")

setup(
    name="dsh_bridge",
    version="1.0.0",
    description="AI-driven UI bridge for ERPNext",
    author="AI Collaborator",
    packages=find_packages(),
    zip_safe=False,
    include_package_data=True,
    install_requires=install_requires
)
