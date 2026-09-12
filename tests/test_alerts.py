import os
import tempfile
import time
import unittest

from collector.store import Store, Metric
from collector.config import AlertThresholds
from collector import alerts


class TestAlertEngine(unittest.TestCase):
    def setUp(self):
        self.tmpdb = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
        self.tmpdb.close()
        self.store = Store(self.tmpdb.name)
        self.thresholds = AlertThresholds(
            capacity_pct_warn=80.0,
            capacity_pct_crit=95.0,
            user_growth_bytes_window=600,
            user_growth_bytes_threshold=5e9,
        )

    def tearDown(self):
        self.store.close()
        os.unlink(self.tmpdb.name)

    def test_capacity_critical_alert_fires(self):
        self.store.write_metrics([Metric("host1", "/", "capacity.used_pct", 97.5, "pct")])
        alerts.check_capacity(self.store, "host1", "/", self.thresholds)
        fired = self.store.recent_alerts()
        self.assertEqual(len(fired), 1)
        self.assertEqual(fired[0]["severity"], "critical")

    def test_capacity_below_threshold_no_alert(self):
        self.store.write_metrics([Metric("host1", "/", "capacity.used_pct", 40.0, "pct")])
        alerts.check_capacity(self.store, "host1", "/", self.thresholds)
        self.assertEqual(len(self.store.recent_alerts()), 0)

    def test_user_growth_alert_fires_on_spike(self):
        now = time.time()
        # simulate a user going from 1GB to 10GB inside the lookback window
        self.store.write_metrics([
            Metric("host1", "/", "capacity.user_bytes", 1e9, "bytes", uid="501", username="alice", ts=now - 300),
        ])
        self.store.write_metrics([
            Metric("host1", "/", "capacity.user_bytes", 10e9, "bytes", uid="501", username="alice", ts=now),
        ])
        alerts.check_user_growth(self.store, "host1", "/", self.thresholds)
        fired = self.store.recent_alerts()
        self.assertEqual(len(fired), 1)
        self.assertIn("alice", fired[0]["message"])
        self.assertEqual(fired[0]["category"], "user_growth")

    def test_user_growth_no_alert_for_gradual_change(self):
        now = time.time()
        self.store.write_metrics([
            Metric("host1", "/", "capacity.user_bytes", 1e9, "bytes", uid="501", username="alice", ts=now - 300),
        ])
        self.store.write_metrics([
            Metric("host1", "/", "capacity.user_bytes", 1.5e9, "bytes", uid="501", username="alice", ts=now),
        ])
        alerts.check_user_growth(self.store, "host1", "/", self.thresholds)
        self.assertEqual(len(self.store.recent_alerts()), 0)

    def test_health_smart_failure_alert(self):
        self.store.write_metrics([Metric("host1", "/", "health.smart_ok", 0.0, "bool")])
        alerts.check_health(self.store, "host1", "/")
        fired = self.store.recent_alerts()
        self.assertTrue(any(a["category"] == "health" for a in fired))


if __name__ == "__main__":
    unittest.main()
