# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0
#
# Build hook for the zpu Python package.  Compiles the shared C library
# libzinput.so from tools/libzinput.c and places it inside the package so the
# ctypes bindings can locate it after installation.

import os
import subprocess
import sys

from setuptools import setup
from setuptools.command.build_py import build_py as _build_py


class build_py(_build_py):
    def run(self):
        root = os.path.dirname(os.path.abspath(__file__))
        src = os.path.join(root, "tools", "libzinput.c")
        hdr_dir = os.path.join(root, "tools")
        dest = os.path.join(root, "zpu", "libzinput.so")

        if not os.path.exists(src):
            raise RuntimeError(
                f"libzinput source not found at {src}; "
                "it should be shipped in the source distribution."
            )

        os.makedirs(os.path.dirname(dest), exist_ok=True)
        cc = os.environ.get("CC", "cc")
        cmd = [
            cc,
            "-O2",
            "-fPIC",
            "-shared",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-I",
            hdr_dir,
            "-o",
            dest,
            src,
        ]
        try:
            subprocess.check_call(cmd)
        except subprocess.CalledProcessError as e:
            sys.stderr.write(f"failed to build libzinput.so: {e}\n")
            raise

        super().run()


setup(
    cmdclass={"build_py": build_py},
    packages=["zpu"],
    package_data={"zpu": ["libzinput.so"]},
    include_package_data=True,
)
