import os
import unittest

from collector.performance import parse_iostat

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")


class TestPerformanceParsing(unittest.TestCase):
    def test_parse_iostat_two_samples(self):
        with open(os.path.join(FIXTURES, "iostat_sample.txt")) as f:
            raw = f.read()
        samples = parse_iostat(raw)

        self.assertEqual(len(samples), 2)
        # first sample is the since-boot average (discarded by collect()),
        # second sample is the live reading we actually care about
        self.assertAlmostEqual(samples[0]["mb_per_s"], 9.50)
        self.assertAlmostEqual(samples[1]["mb_per_s"], 45.60)
        self.assertAlmostEqual(samples[1]["tps"], 91.0)
        self.assertAlmostEqual(samples[1]["kb_per_transfer"], 512.02)

    def test_parse_iostat_empty(self):
        self.assertEqual(parse_iostat("no numeric rows here"), [])

    def test_gbps_conversion(self):
        # collect() divides mb_per_s by 1024 to report GB/s
        mb_s = 45.60
        self.assertAlmostEqual(mb_s / 1024.0, 0.04453, places=5)


if __name__ == "__main__":
    unittest.main()
