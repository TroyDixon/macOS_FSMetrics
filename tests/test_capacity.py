import os
import shutil
import tempfile
import unittest

from collector.capacity import scan_usage_by_uid, largest_paths, username_for_uid


class TestCapacityScan(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        # Build a small real tree and write real files with known sizes.
        # We can't chown() without root, so every file is owned by the
        # current process's uid -- the point of this test is that the walk +
        # aggregation logic is correct, which is OS-owner-independent.
        os.makedirs(os.path.join(self.tmpdir, "sub"))
        with open(os.path.join(self.tmpdir, "a.txt"), "wb") as f:
            f.write(b"x" * 1000)
        with open(os.path.join(self.tmpdir, "sub", "b.txt"), "wb") as f:
            f.write(b"y" * 2500)

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_scan_usage_by_uid_totals_all_bytes(self):
        totals = scan_usage_by_uid([self.tmpdir])
        my_uid = os.getuid()
        self.assertIn(my_uid, totals)
        self.assertEqual(totals[my_uid], 3500)

    def test_scan_usage_ignores_unreadable_dirs_gracefully(self):
        # A path that doesn't exist shouldn't raise -- monitoring tools must
        # degrade gracefully, not crash the whole poll cycle.
        totals = scan_usage_by_uid([os.path.join(self.tmpdir, "does-not-exist")])
        self.assertEqual(totals, {})

    def test_largest_paths_sorted_descending(self):
        top = largest_paths([self.tmpdir], top_n=5)
        sizes = [size for _, size in top]
        self.assertEqual(sizes, sorted(sizes, reverse=True))
        self.assertEqual(sizes[0], 2500)

    def test_username_for_uid_falls_back_to_str(self):
        # An absurd uid should never crash the collector -- it should
        # degrade to the string form.
        self.assertEqual(username_for_uid(2**31), str(2**31))


if __name__ == "__main__":
    unittest.main()
