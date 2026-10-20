import sys

sys.path.insert(0, sys.argv[1])
import parity_ext  # noqa: E402

print(f"parity_ext.add(2, 3) = {parity_ext.add(2, 3)}")
