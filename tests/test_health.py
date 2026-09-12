import os
import unittest

from collector.health import parse_diskutil_info_plist, capacity_pct

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")


class TestHealthParsing(unittest.TestCase):
    def test_parse_diskutil_info_plist(self):
        with open(os.path.join(FIXTURES, "diskutil_info.plist"), "rb") as f:
            raw = f.read()
        info = parse_diskutil_info_plist(raw)

        self.assertEqual(info["device_identifier"], "disk3s1")
        self.assertEqual(info["filesystem"], "apfs")
        self.assertEqual(info["smart_status"], "Verified")
        self.assertEqual(info["total_bytes"], 2000398934016)
        self.assertEqual(info["free_bytes"], 734003855360)
        self.assertEqual(info["used_bytes"], 2000398934016 - 734003855360)
        self.assertTrue(info["encrypted"])
        self.assertTrue(info["writable"])
        self.assertFalse(info["removable_media"])

    def test_capacity_pct(self):
        self.assertAlmostEqual(capacity_pct(50, 100), 50.0)
        self.assertEqual(capacity_pct(10, 0), 0.0)  # guard against div-by-zero
        self.assertAlmostEqual(capacity_pct(1266395078656, 2000398934016), 63.31, places=1)


if __name__ == "__main__":
    unittest.main()
