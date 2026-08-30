# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0
#
# Standalone wrapper for the zpu.zinput module.
#
# The implementation lives in zpu/zinput.py so it is packaged on PyPI as part of
# the `zpu` distribution.  This file only exists so the repo's tools/ directory
# can still be used directly when the package is not installed.

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from zpu.zinput import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
