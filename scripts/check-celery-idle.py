#!/usr/bin/env python3
"""Read worker state and Redis transport queues; never purge or consume tasks.

Run through stdin in the synthetic Paperless pod, with its existing settings.
No broker URLs, task payloads, or credentials are printed, including on errors.
"""

import json
import signal
import sys


def snapshot(app, expected_workers=1):
    inspector = app.control.inspect(timeout=5)
    ping = inspector.ping()
    workers = set(ping or {})
    if len(workers) != expected_workers:
        raise ValueError("Missing or unexpected worker")
    # Once the worker set is established, directed replies complete as soon as
    # all expected workers answer instead of waiting out every broadcast timeout.
    inspector.destination = sorted(workers)
    replies = {"ping": ping}
    replies.update({name: getattr(inspector, name)() for name in
                    ("active", "reserved", "scheduled", "active_queues")})
    for name, response in replies.items():
        if not isinstance(response, dict) or set(response) != workers:
            raise ValueError("Incomplete worker response")
        if name != "ping" and any(not isinstance(tasks, list) for tasks in response.values()):
            raise ValueError("Malformed worker response")
    if any(reply != {"ok": "pong"} for reply in replies["ping"].values()):
        raise ValueError("Worker ping failed")
    queues = set(app.amqp.queues)
    for worker_queues in replies["active_queues"].values():
        if not worker_queues:
            raise ValueError("Worker has no queues")
        for queue in worker_queues:
            if not isinstance(queue, dict) or not isinstance(queue.get("name"), str) or not queue["name"]:
                raise ValueError("Malformed queue name")
            queues.add(queue["name"])
    if not queues:
        raise ValueError("No queues discovered")
    counts = {name: sum(len(tasks) for tasks in replies[name].values())
              for name in ("active", "reserved", "scheduled")}
    with app.connection_for_read() as connection:
        if connection.transport.driver_type != "redis":
            raise ValueError("Only the tested Redis/Valkey transport is supported")
        with connection.channel() as channel:
            # Redis deletes empty lists. Passive AMQP-style declarations can
            # therefore return NOT_FOUND for a correctly drained Redis queue.
            # Read every Kombu priority bucket directly; LLEN of an absent key
            # is zero. The channel client preserves any configured key prefix.
            if not channel.priority_steps:
                raise ValueError("Redis priority configuration is empty")
            with channel.client.pipeline() as pipeline:
                for queue in sorted(queues):
                    for priority in channel.priority_steps:
                        pipeline.llen(channel._q_for_pri(queue, priority))
                sizes = pipeline.execute()
            if len(sizes) != len(queues) * len(channel.priority_steps) or any(
                    type(size) is not int or size < 0 for size in sizes):
                raise ValueError("Incomplete Redis priority queue counts")
            counts["queued"] = sum(sizes)
            if not channel.ack_emulation:
                raise ValueError("Redis acknowledgement tracking is disabled")
            counts["unacked"] = channel.client.hlen(channel.unacked_key)
            counts["unacked_index"] = channel.client.zcard(channel.unacked_index_key)
    if any(type(count) is not int or count < 0 for count in counts.values()):
        raise ValueError("Invalid queue counts")
    return counts


def main():
    def deadline(_signum, _frame):
        raise TimeoutError("Broker snapshot deadline exceeded")

    signal.signal(signal.SIGALRM, deadline)
    signal.alarm(45)
    try:
        from paperless.celery import app
        counts = snapshot(app)
        print(json.dumps(counts, sort_keys=True))
        return 0 if all(count == 0 for count in counts.values()) else 3
    except Exception as error:
        # Exceptions from Redis/Celery can contain credential-bearing URLs.
        print(f"Cannot establish complete broker/worker idle state ({type(error).__name__})", file=sys.stderr)
        return 2
    finally:
        signal.alarm(0)


if __name__ == "__main__":
    sys.exit(main())
