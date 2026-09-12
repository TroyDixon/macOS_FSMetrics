import os
import unittest

from collector.nfs_shared import parse_nfsstat_m, parse_nfsstat_client_counters

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")


class TestNfsParsing(unittest.TestCase):
    def test_parse_nfsstat_m_two_mounts(self):
        with open(os.path.join(FIXTURES, "nfsstat_m_sample.txt")) as f:
            raw = f.read()
        mounts = parse_nfsstat_m(raw)

        self.assertEqual(len(mounts), 2)

        research = next(m for m in mounts if m.mount_point == "/Volumes/Research")
        self.assertEqual(research.server, "fileserver.lab.local:/export/research")
        self.assertTrue(research.pnfs)

        scratch = next(m for m in mounts if m.mount_point == "/Volumes/Scratch")
        self.assertFalse(scratch.pnfs)

    def test_parse_client_counters(self):
        raw = "read: 1234\nwrite: 567\ntimeout: 3\nretrans: 1\n"
        counters = parse_nfsstat_client_counters(raw)
        self.assertEqual(counters["read"], 1234)
        self.assertEqual(counters["timeout"], 3)


if __name__ == "__main__":
    unittest.main()
