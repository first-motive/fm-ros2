# fm_policy_serve

Inference serving. Feeds predictions to the autonomy arbiter.
**Placeholder stub** — the `server` node only logs that it is up; no inference
logic, topics, or parameters yet.

## Role

```
fm_policy_serve -> autonomy arbiter (deferred: fm_fsm)
```

## Run

```bash
ros2 run fm_policy_serve server
```

## Build Type

`ament_python`.
