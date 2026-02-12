# Restore /keepalive Endpoint

## Feature Issue
GitHub Issue #228 | Milestone: R6: Agent Isolation (bug fix)

## Overview
The `/keepalive` POST endpoint allows external monitors (iOS Shortcuts, cron jobs,
scheduled automations) to reset a droplet's self-destruct timer. When called, it
stops the current `self-destruct.timer` systemd unit, clears any failed state, and
re-runs `schedule-destruct.sh` to restart the countdown from scratch. This keeps the
droplet alive as long as the caller is actively pinging it.

The endpoint was present in the inline cloud-config YAML (v2.45–v3.1) but was
accidentally dropped when `api-server.py` was extracted to `scripts/api-server.py`
during the v3.11 two-phase boot rewrite.

## API Contract

| Field    | Value                                    |
|----------|------------------------------------------|
| Method   | `POST`                                   |
| Path     | `/keepalive`                             |
| Auth     | HMAC signature required (X-Signature header) |
| Request  | Empty body (no JSON payload required)    |
| Response | `{"ok": true}` or `{"ok": false, "error": "<message>"}` |
| Status   | `200 OK` on success, `500` on subprocess failure |

### Authentication
The endpoint MUST require HMAC authentication, consistent with all other mutation
endpoints (`/sync`, `/prepare-shutdown`, `/config/upload`, `/config/apply`). Requests
without a valid `X-Signature` header receive `403 Forbidden`.

## Implementation Approach

### Location in api-server.py
Add the `/keepalive` handler inside `do_POST()`, following the same pattern as
existing mutation endpoints. Place it after the `/prepare-shutdown` handler since
both deal with droplet lifecycle management.

### Handler Structure
```python
elif self.path=='/keepalive':
    timestamp=self.headers.get('X-Timestamp')
    signature=self.headers.get('X-Signature')
    ok,err=verify_hmac_auth(timestamp, signature, self.command, self.path, body)
    if not ok:
        self.send_json(403,{"ok":False,"error":err or "Forbidden"});return

    try:
        subprocess.run(
            ["systemctl","stop","self-destruct.timer","self-destruct.service"],
            capture_output=True,timeout=10
        )
        subprocess.run(
            ["systemctl","reset-failed","self-destruct.timer"],
            capture_output=True,timeout=10
        )
        subprocess.run(
            ["/usr/local/bin/schedule-destruct.sh"],
            check=True,capture_output=True,timeout=30
        )
        self.send_json(200,{"ok":True})
    except Exception as e:
        self.send_json(500,{"ok":False,"error":str(e)})
```

### Key Differences from Original
1. **HMAC auth**: Original had no auth; new version uses `verify_hmac_auth()` with
   `X-Timestamp` and `X-Signature` headers, matching all other mutation endpoints.
2. **`send_json()` helper**: Uses `self.send_json(code, data)` instead of manual
   `send_response`/`send_header`/`end_headers`/`wfile.write`, consistent with the
   rest of the API surface.
3. **No `shell=True`**: Original used a single `shell=True` command string.
   New version uses three separate `subprocess.run()` calls with argument arrays,
   per the security standard established in commit `5df0730`.
4. **`capture_output=True`**: Prevents subprocess output from leaking to server logs.
5. **`check=True` on schedule-destruct.sh only**: The `systemctl stop` and
   `reset-failed` calls omit `check` since the timer may not be running.
   The `schedule-destruct.sh` call uses `check=True` to surface real failures.
6. **Timeouts**: Each subprocess call has an explicit timeout to prevent hangs.

### Header Comment Update
Add `/keepalive` to the endpoint table in the `api-server.py` file header:
```
# POST /keepalive      - Reset self-destruct timer (HMAC required)
```

## Security Considerations

- **HMAC required**: Without authentication, any network scanner could keep a
  droplet alive indefinitely, defeating the self-destruct safety mechanism.
- **No shell=True**: Subprocess calls use array form to prevent command injection.
- **No user input in subprocess args**: The endpoint takes no parameters—all
  arguments are hardcoded paths and unit names.
- **Error sanitization**: `str(e)` is returned on failure. Since no user input
  flows into the exception, this does not leak sensitive data.

## Test Plan

Tests go in `tests/test_keepalive.py` (or extend `tests/test_api_auth.py`).

### Test Cases

| # | Test | Description |
|---|------|-------------|
| 1 | `test_keepalive_requires_auth` | POST without HMAC header returns 403 |
| 2 | `test_keepalive_invalid_sig` | POST with wrong HMAC signature returns 403 |
| 3 | `test_keepalive_success` | POST with valid HMAC returns `{"ok": true}` |
| 4 | `test_keepalive_subprocess_error` | When schedule-destruct.sh fails, returns `{"ok": false, "error": "..."}` |
| 5 | `test_keepalive_method_not_allowed` | GET /keepalive returns 405 or is ignored |
| 6 | `test_keepalive_no_shell_true` | Source inspection: no `shell=True` in keepalive handler |
| 7 | `test_keepalive_documented` | `/keepalive` appears in api-server.py header comment |

### Test Approach
- Mock `subprocess.run` to avoid requiring real systemd units.
- Use the same HMAC test fixtures as `test_api_auth.py`.
- For test 6, parse the source file to verify no `shell=True` in the keepalive block.

## Dependencies
- `scripts/schedule-destruct.sh` (already exists, 6 lines)
- `scripts/kill-droplet.sh` (already exists, called by schedule-destruct.sh)
- systemd runtime environment (mocked in tests)

## Rollout
No migration needed. The endpoint is additive—existing clients that don't call
`/keepalive` are unaffected. Clients that previously called the endpoint will
start working again once the fix is deployed.
