# Time-off requests — Lightning Bolt API (captured 2026-09-29)

Captured by a safe dry-run: a fetch/XHR interceptor in Nicolaas's own logged-in LB web session **blocked every send**, so nothing was submitted or deleted. The real pending request (Ouma B-Day, 26–28 Mar 2027) was untouched.

This is Matt's request: submit time-off / night-off requests from Working-Bolt, see their status, and cancel them.

In the LB web UI the path is Viewer → **My** icon → Request → Time off / Night off. You pick dates, add a reason, and press Submit.

## Submit — `POST https://lbapi.lightning-bolt.com/request` (Bearer)
LB sends one array element per day:
```json
[ { "type":"new", "emp_id":20147, "date":"2027-03-27T00:00:00",
    "assign_id":20248, "assign_structure_id":343, "assign_name":"Time Off",
    "template_id":6, "command_type":0, "note":"ouma bday",
    "start_date":null, "end_date":null } ]
```

| Kind | assign_id | assign_structure_id | assign_name |
|---|---|---|---|
| Time off | 20248 | 343 | "Time Off" (24h, 08:00 → 08:00 next day) |
| Night off | 20251 | 346 | "Night Off" |

- Time "Default" was selected; the "Custom" time option was not captured.
- `template_id` 6 = Critical Care (ICU).

## Cancel / delete — `POST /request`
```json
[ { "type":"delete", "request_id":73359, "decision_note":null } ]
```
Each day is a separate `request_id`. A multi-day request means one element per day.

## List my requests — `GET /request/range/?start_date=YYYYMMDD&end_date=YYYYMMDD&listed=true&emp_id=<EMP>`
Returns `{ request_count, data:[…] }`. Each item has:
- `request_id`, `request_date` (YYYY-MM-DD)
- `status` ("pending", approved, denied, …)
- `assign_id`, `assign_display_name` ("Time Off")
- `start_time`, `stop_time`
- `message` (the note), `timestamp` (when it was submitted)
- `decision_msg`, `denial_reason_name`
- `created_by_display_name`, `modified_by_display_name`, `modified_timestamp`
- `template_id`, `department_id`, `loa_reason_*`

The LB web UI pages through this list by month.

## Safety for the app
- It acts **only on the signed-in user's own requests**, and every submit or cancel needs an explicit confirm.
- It never approves or denies anything, and never touches anyone else's requests.
- It needs demo-mode write guards, like the give-away flow.
