#!/usr/bin/env python3
import importlib.util
from pathlib import Path
from unittest import TestCase, main
from unittest.mock import MagicMock

spec = importlib.util.spec_from_file_location("idle", Path(__file__).with_name("check-celery-idle.py"))
idle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(idle)


class IdleTests(TestCase):
    def setUp(self):
        self.app = MagicMock()
        self.inspect = self.app.control.inspect.return_value
        self.inspect.ping.return_value = {"worker": {"ok": "pong"}}
        for state in ("active", "reserved", "scheduled"):
            getattr(self.inspect, state).return_value = {"worker": []}
        self.inspect.active_queues.return_value = {"worker": [{"name": "celery"}]}
        self.app.amqp.queues = {"celery": None, "unused": None}
        self.connection = self.app.connection_for_read.return_value.__enter__.return_value
        self.connection.transport.driver_type = "redis"
        self.channel = self.connection.channel.return_value.__enter__.return_value
        self.channel.ack_emulation = True
        self.channel.priority_steps = [0, 3, 6, 9]
        self.channel._q_for_pri.side_effect = lambda q, p: q if not p else f"{q}\x06\x16{p}"
        self.pipeline = self.channel.client.pipeline.return_value.__enter__.return_value
        self.pipeline.execute.return_value = [0] * 8
        self.channel.client.hlen.return_value = 0
        self.channel.client.zcard.return_value = 0

    def test_empty_broker_and_all_workers(self):
        self.assertTrue(all(v == 0 for v in idle.snapshot(self.app).values()))
        self.channel.queue_declare.assert_not_called()
        self.pipeline.llen.assert_any_call("celery")
        self.pipeline.llen.assert_any_call("celery\x06\x169")
        self.pipeline.llen.assert_any_call("unused\x06\x169")

    def test_tasks_not_limited_to_first_api_page(self):
        self.pipeline.execute.return_value = [0, 0, 0, 101, 0, 0, 0, 0]
        self.assertEqual(idle.snapshot(self.app)["queued"], 101)

    def test_incomplete_or_invalid_priority_counts_fail_closed(self):
        for values in ([0], [0] * 7 + [None], [0] * 7 + [-1]):
            self.pipeline.execute.return_value = values
            with self.assertRaises(ValueError):
                idle.snapshot(self.app)

    def test_each_worker_and_broker_state_blocks_idle(self):
        for state in ("active", "reserved", "scheduled"):
            getattr(self.inspect, state).return_value = {"worker": [{"id": "private"}]}
            self.assertEqual(idle.snapshot(self.app)[state], 1)
            getattr(self.inspect, state).return_value = {"worker": []}
        self.channel.client.hlen.return_value = 1
        self.channel.client.zcard.return_value = 2
        self.assertEqual(idle.snapshot(self.app)["unacked"], 1)
        self.assertEqual(idle.snapshot(self.app)["unacked_index"], 2)

    def test_missing_worker_response_fails_closed(self):
        for method in ("ping", "active", "reserved", "scheduled", "active_queues"):
            with self.subTest(method=method):
                original = getattr(self.inspect, method).return_value
                getattr(self.inspect, method).return_value = None
                with self.assertRaises(ValueError):
                    idle.snapshot(self.app)
                getattr(self.inspect, method).return_value = original

    def test_extra_worker_response_fails_closed(self):
        self.inspect.active.return_value = {"worker": [], "unexpected": []}
        with self.assertRaises(ValueError):
            idle.snapshot(self.app)

    def test_unsupported_transport_and_ack_configuration(self):
        self.connection.transport.driver_type = "amqp"
        with self.assertRaises(ValueError):
            idle.snapshot(self.app)
        self.connection.transport.driver_type = "redis"
        self.channel.ack_emulation = False
        with self.assertRaises(ValueError):
            idle.snapshot(self.app)


if __name__ == "__main__":
    main()
