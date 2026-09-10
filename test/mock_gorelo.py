#!/usr/bin/env python3
"""A fake Gorelo API for testing the MCP server without touching a live tenant.

Self-contained: all data is generated here, nothing is read from disk, and no
real client or user information is involved.

It mirrors the real API's awkward parts on purpose, because those are what
break things:

  * PascalCase fields inside a {StatusCode, IsSuccess, Data, DataContext,
    Notifications} envelope
  * CURSOR pagination via DataContext.Pagination.NextCursor / HasMore
  * PageSize clamped to 1..200
  * /v1/tickets/statuses does NOT list the "Merged" status, even though
    tickets use it
  * LeadAssigneeIds filters, but there is no assisting-assignee filter:
    AssistingAssigneeIds, AssigneeIds and WatcherIds are response fields only,
    and are accepted then silently ignored as query parameters
  * `Query` is the search parameter, matching title, number and display number
  * unknown query parameters are ignored rather than rejected, so a wrong
    name looks like a successful call that returns everything
  * 429 rate limiting with a retry_after

Run it:  python3 mock_gorelo.py        (listens on 127.0.0.1:8899)
"""
import json
import base64
import re
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

KEY = "test-key-123"
PORT = 8899
ME = 2907          # the "logged in" user
OTHER = 3001       # a colleague

NOW = datetime.now(timezone.utc)


def ago(days, hours=0):
    return (NOW - timedelta(days=days, hours=hours)).isoformat().replace("+00:00", "Z")


# --- statuses -------------------------------------------------------------
# Deliberately does NOT include id 5 "Merged" (real Gorelo omits it) and does
# NOT include id 364 "Waiting Vendor" (stands in for any status an instance has
# that this endpoint fails to return). Both must still be handled correctly.
STATUSES = [
    {"Id": 1,   "Name": "New",              "BaseStatusId": 1, "AskForReason": False},
    {"Id": 2,   "Name": "Open",             "BaseStatusId": 2, "AskForReason": False},
    {"Id": 3,   "Name": "Solved",           "BaseStatusId": 3, "AskForReason": False},
    {"Id": 4,   "Name": "Closed",           "BaseStatusId": 4, "AskForReason": False},
    {"Id": 6,   "Name": "On Hold",          "BaseStatusId": 6, "AskForReason": True},
    {"Id": 362, "Name": "Scheduled",        "BaseStatusId": 2, "AskForReason": True},
    {"Id": 363, "Name": "Waiting Client",   "BaseStatusId": 6, "AskForReason": True},
    {"Id": 798, "Name": "Quote Required",   "BaseStatusId": 2, "AskForReason": False},
    {"Id": 799, "Name": "Standing Ticket",  "BaseStatusId": 3, "AskForReason": False},
    {"Id": 807, "Name": "Billing",          "BaseStatusId": 3, "AskForReason": True},
]
UNLISTED_MERGED = {"Id": 5, "Name": "Merged"}
UNLISTED_OTHER = {"Id": 364, "Name": "Waiting Vendor"}

CLIENTS = [
    {"Id": 11001, "Name": "Northwind Traders", "IsActive": True},
    {"Id": 11002, "Name": "Contoso Engineering", "IsActive": True},
    {"Id": 11003, "Name": "Fabrikam Legal", "IsActive": True},
    {"Id": 11004, "Name": "Tailspin Freight", "IsActive": True},
    {"Id": 11005, "Name": "Proseware Dental", "IsActive": True},
    {"Id": 11006, "Name": "Wingtip Property Group", "IsActive": True},
    # Two names for one account that share no substring, to exercise
    # comma-separated client matching.
    {"Id": 11007, "Name": "Adventure Works", "IsActive": True},
    {"Id": 11008, "Name": "AWX Holdings", "IsActive": False},
]

USERS = [
    {"Id": ME,    "FirstName": "Sam", "LastName": "Rivers", "Email": "sam@example.com",
     "Status": {"Id": 2, "Name": "Active"}},
    {"Id": OTHER, "FirstName": "Alex", "LastName": "Kim", "Email": "alex@example.com",
     "Status": {"Id": 2, "Name": "Active"}},
    {"Id": 3002,  "FirstName": "Jordan", "LastName": "Lee", "Email": "jordan@example.com",
     "Status": {"Id": 3, "Name": "Archived"}},
]

CONTACTS = []
for i, c in enumerate(CLIENTS):
    for j, (first, last) in enumerate([("Dana", "Ellis"), ("Kim", "Nguyen"), ("Pat", "Doyle")]):
        CONTACTS.append({
            "Id": 100000 + i * 10 + j, "ClientId": c["Id"],
            "FirstName": first, "LastName": last,
            "Email": f"{first.lower()}.{last.lower()}{i}@example.com",
            "Phone": f"07 5550 {i:02d}{j:02d}"})

AGENTS = []
for i, c in enumerate(CLIENTS):
    for j in range(4):
        AGENTS.append({
            "Id": f"agent-{i}-{j}", "ClientId": c["Id"],
            "Name": f"WS-{i:02d}{j}",
            "OsName": "Windows 10 Pro" if j == 0 else "Windows 11 Pro",
            "Description": "", "WarrantyStartDate": None, "WarrantyEndDate": None,
            # One stale device per client, to exercise stale_days.
            "LastSeenOn": ago(140) if j == 0 else ago(1)})

# Gorelo exposes no asset TAGS through the API, so anything that must be
# reportable has to live in Description or WarrantyExpiryDate. Two rental
# devices carry a contract end date the way a real deployment would.
AGENTS[1]["Description"] = "Client Rental Asset - ContractEnd Sep2026"
AGENTS[1]["WarrantyEndDate"] = "2026-09-30T00:00:00Z"
AGENTS[1]["WarrantyStartDate"] = "2024-09-30T00:00:00Z"
# One agent deliberately still carries the PRE-2026-08-21 field name, so the
# suite proves the reader falls back for a tenant that has not had the update.
AGENTS[2]["WarrantyExpiryDate"] = "2027-01-15T00:00:00Z"
AGENTS[5]["Description"] = "Client Rental Asset - Term Concluded - ContractEnd Aug2026"

# --- tickets --------------------------------------------------------------
# 60 tickets, deterministic, covering every case the server has to get right.
# Spread across the usual shape: mostly quick, a long tail, one very bad one.
SLA_MINUTES = [4.5, 12.0, 18.25, 33.0, 47.5, 61.0, 88.0, 145.5, 260.0, 1180.75]

# Groups are how separate desks or brands are modelled - each can carry its own
# outbound helpdesk address, so they are a genuine reporting dimension.
GROUPS = [
    {"Id": 1, "Name": "Everyone", "Alias": "everyone",
     "OutboundEmail": "helpdesk@example.com"},
    {"Id": 2, "Name": "Second Brand", "Alias": "second",
     "OutboundEmail": "helpdesk@secondbrand.example"},
]

TICKETS = []


def make(n, status, client, title, lead=ME, assisting=None, watchers=None,
         created=200, updated=None, reason=None):
    updated = created if updated is None else updated
    t = {
        "Id": f"00000000-0000-0000-0000-{n:012d}",
        "Number": n, "DisplayNumber": f"G-{n}",
        "Title": title,
        "ClientId": client,
        "ContactId": 100000, "CcContactIds": [],
        "LeadAssigneeId": lead,
        "AssistingAssigneeIds": assisting or [],
        "WatcherIds": watchers or [],
        "GroupIds": [1 if n % 3 else 2], "PrimaryGroupId": 1 if n % 3 else 2,
        "Status": {"Id": status["Id"], "Name": status["Name"]},
        "StatusUpdatedOn": ago(updated),
        "StatusReason": json.dumps(
            {"reason": reason, "updatedById": ME, "updatedOn": ago(updated)}) if reason else "",
        "Priority": {"Id": 3, "Name": "Normal"},
        "Source": {"Id": 2, "Name": "Email"},
        "Type": {"Id": 1, "Name": "Incident"},
        "TagIds": [], "IsUnread": False, "IsWaitingOnThem": False,
        # Sla.FirstResponse.ElapsedBusinessMinutes arrived (renamed) on
        # 2026-08-21. Deliberately varied, and deliberately ABSENT on some
        # tickets - a ticket that never got a first response has no SLA node at
        # all, and a report that silently drops those flatters itself.
        "Sla": ({"FirstResponse": {"ElapsedBusinessMinutes": SLA_MINUTES[n % len(SLA_MINUTES)]}}
                if n % 7 else None),
        "ChecklistSummary": None,
        "IsMerged": False,           # NOTE: false even on merged tickets, as in real data
        "MergedIntoTicketId": None, "MergedTicketIds": [],
        "LastUpdate": {"UpdateType": "CommentCreated", "Summary": "status updated",
                       "On": ago(updated)},
        "CreatedOn": ago(created), "UpdatedOn": ago(updated),
        "ClosedOn": ago(updated) if status["Id"] == 4 else None,
    }
    TICKETS.append(t)
    return t


by_id = {s["Id"]: s for s in STATUSES}
n = 1000

# 20 ordinary open tickets led by ME, spread across active statuses
for i, sid in enumerate([1, 2, 2, 2, 362, 362, 363, 6, 798, 798,
                         2, 362, 2, 798, 6, 363, 2, 362, 2, 1]):
    make(n, by_id[sid], CLIENTS[i % len(CLIENTS)]["Id"],
         f"Open work item {i + 1}", created=180 - i * 7, updated=120 - i * 5,
         reason=f"waiting on part {i + 1}" if by_id[sid]["AskForReason"] else None)
    n += 1

# 8 in the SOLVED base led by ME (Billing / Standing) - real work, must not be
# treated as done
for i, sid in enumerate([807, 807, 807, 799, 807, 799, 3, 807]):
    make(n, by_id[sid], CLIENTS[i % len(CLIENTS)]["Id"],
         f"Solved-base item {i + 1}", created=150 - i * 9, updated=100 - i * 8,
         reason=f"needs invoicing: item {i + 1}" if by_id[sid]["AskForReason"] else None)
    n += 1

# 14 MERGED tickets - status id 5, which /v1/tickets/statuses never returns,
# and IsMerged is false. Must be excluded from counts and named as excluded.
for i in range(14):
    make(n, UNLISTED_MERGED, CLIENTS[i % len(CLIENTS)]["Id"],
         f"Duplicate of another ticket {i + 1}", created=100 - i * 3, updated=90 - i * 3)
    n += 1

# 2 tickets in a status the statuses endpoint does not return, and which is NOT
# merged. These must be surfaced with a warning, never silently dropped.
for i in range(2):
    make(n, UNLISTED_OTHER, CLIENTS[i]["Id"], f"Waiting on a vendor {i + 1}",
         created=60 - i * 5, updated=50 - i * 5, reason="vendor has not replied")
    n += 1

# 9 unclosed tickets led by someone else, with ME assisting. Only reachable by
# sweeping the org-wide unclosed list.
ASSIST = []
for i, sid in enumerate([2, 2, 362, 798, 6, 2, 363, 807, 2]):
    ASSIST.append(make(n, by_id[sid], CLIENTS[i % len(CLIENTS)]["Id"],
                       f"Assisting item {i + 1}", lead=OTHER, assisting=[ME],
                       created=80 - i * 4, updated=70 - i * 4))
    n += 1

# 2 CLOSED tickets where ME assists - must NOT appear in an unclosed count
CLOSED_ASSIST = [make(n + i, by_id[4], CLIENTS[i]["Id"], f"Closed assist {i + 1}",
                      lead=OTHER, assisting=[ME], created=200, updated=30)
                 for i in range(2)]
n += 2

# 1 ticket where ME is only a watcher - must NOT be counted as mine
WATCHER_ONLY = make(n, by_id[2], CLIENTS[0]["Id"], "Watching only", lead=OTHER,
                    watchers=[ME], created=40, updated=20)
n += 1

# 20 genuinely closed tickets led by ME
for i in range(20):
    make(n, by_id[4], CLIENTS[i % len(CLIENTS)]["Id"], f"Closed item {i + 1}",
         created=300 - i * 5, updated=200 - i * 5)
    n += 1

# Time fixtures for the get-by-id detail. Two deliberate cases:
#   - a ticket with hours recorded, adjusted UP, all billable
#   - a ticket in Billing with NO time recorded at all, which is the state that
#     silently costs money and which the API could not report before 2026-08-21
TICKET_TIME = {}
_by_number = {t["Number"]: t["Id"] for t in TICKETS}
# A Billing-status ticket with billable hours, so the review tool has one of
# each group to sort: billable, recorded-but-not-billable, and no time at all.
for _t in TICKETS:
    if _t.get("Status", {}).get("Name") == "Billing":
        TICKET_TIME[_t["Id"]] = {
            "ActualHours": 1.9, "AdjustedHours": 2.0,
            "Breakdown": {
                "Billable": {"ActualHours": 1.9, "AdjustedHours": 2.0},
                "NotBillable": {"ActualHours": 0.0, "AdjustedHours": 0.0},
                "NotBillableHidden": {"ActualHours": 0.0, "AdjustedHours": 0.0},
            }}
        break

if 1000 in _by_number:
    TICKET_TIME[_by_number[1000]] = {
        "ActualHours": 1.75, "AdjustedHours": 2.0,
        "Breakdown": {
            "Billable": {"ActualHours": 1.75, "AdjustedHours": 2.0},
            "NotBillable": {"ActualHours": 0.0, "AdjustedHours": 0.0},
            "NotBillableHidden": {"ActualHours": 0.0, "AdjustedHours": 0.0},
        }}

# A ticket whose time is recorded but is NOT billable - the leakage case.
# Must be assigned LAST: without it every realisation figure reads 100%, which
# is exactly the reassuring-but-wrong output a report like this can produce.
for _t in TICKETS:
    if _t["Id"] not in TICKET_TIME and _t.get("Status", {}).get("Name") != "Merged":
        TICKET_TIME[_t["Id"]] = {
            "ActualHours": 1.2, "AdjustedHours": 1.2,
            "Breakdown": {
                "Billable": {"ActualHours": 0.0, "AdjustedHours": 0.0},
                "NotBillable": {"ActualHours": 1.2, "AdjustedHours": 1.2},
                "NotBillableHidden": {"ActualHours": 0.0, "AdjustedHours": 0.0},
            }}
        break

MINE_UNCLOSED_LEAD = [t for t in TICKETS
                      if t["LeadAssigneeId"] == ME
                      and t["Status"]["Id"] not in (4, 5)]

# --- comments -------------------------------------------------------------
# Schema copied from a real response.
FIRST_OPEN = TICKETS[0]["Id"]
COMMENTS = {
    FIRST_OPEN: [
        {"Id": "c1", "BodyTruncated": True, "ConversationId": None,
         "ConversationType": {"Id": 1, "Name": "Public"},
         "Source": {"Id": 2, "Name": "Email"},
         "BodyHtml": "",
         "BodyText": "Could you confirm the quote?\n\n\n\nWe agreed $3.75 ex per mailbox.",
         "Author": {"Type": "Contact", "Id": 100000, "Name": "Dana Ellis",
                    "Email": "dana.ellis0@example.com"},
         "Attachments": [{"Id": "a1", "Name": "quote.pdf"}],
         "CreatedOn": ago(10), "UpdatedOn": None},
        {"Id": "c2", "BodyTruncated": False, "ConversationId": None,
         "ConversationType": {"Id": 2, "Name": "Private"},
         "Source": {"Id": 1, "Name": "Web"},
         "BodyHtml": "<p>Internal note: check the contract first.</p>", "BodyText": "",
         "Author": {"Type": "User", "Id": ME, "Name": "Sam Rivers",
                    "Email": "sam@example.com"},
         "Attachments": [], "CreatedOn": ago(9), "UpdatedOn": None},
        # Gorelo's API currently returns DELETED comments with no flag at all,
        # while the web UI shows "This comment has been deleted". This entry
        # carries the flag Gorelo would send IF it ever ships one, so the
        # server's handling is exercised.
        {"Id": "c3", "BodyTruncated": False, "IsDeleted": True,
         "ConversationType": {"Id": 2, "Name": "Private"},
         "Source": {"Id": 1, "Name": "Web"},
         "BodyHtml": "", "BodyText": "SENSITIVE-MUST-NOT-BE-PRINTED",
         "Author": {"Type": "User", "Id": OTHER, "Name": "Alex Kim"},
         "Attachments": [], "CreatedOn": ago(8), "UpdatedOn": None},
    ]
}

POSTED = []


def env(data, pagination=None):
    return {"StatusCode": 200, "IsSuccess": True, "Data": data,
            "DataContext": {"Pagination": pagination} if pagination else None,
            "Notifications": []}


def fail(code, message):
    return {"StatusCode": code, "IsSuccess": False, "Data": None,
            "Notifications": [{"Message": message}]}


def paginate(rows, q):
    size = max(1, min(200, int(q.get("PageSize", ["50"])[0])))
    start = 0
    cur = q.get("Cursor", [None])[0]
    if cur:
        try:
            start = int(base64.b64decode(cur).decode())
        except Exception:
            start = 0
    page = rows[start:start + size]
    nxt = start + size
    more = nxt < len(rows)
    return page, {"NextCursor": base64.b64encode(str(nxt).encode()).decode() if more else None,
                  "PreviousCursor": None, "HasMore": more, "HasPrevious": start > 0,
                  "TotalCount": len(rows)}


class Handler(BaseHTTPRequestHandler):
    flaky = 0

    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorised(self):
        if self.headers.get("X-API-Key") != KEY:
            self.reply(401, fail(401, "Invalid API key"))
            return False
        return True

    def do_PATCH(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        path = urlparse(self.path).path
        m = re.fullmatch(r"/v1/tickets/([^/]+)", path)
        if not m:
            return self.reply(404, fail(404, "Not found"))
        hit = next((t for t in TICKETS if t["Id"] == m.group(1)), None)
        if not hit:
            return self.reply(404, fail(404, "Ticket not found"))

        # THE POINT: unrecognised fields are IGNORED, not rejected - exactly as
        # the real API treats unknown query parameters. Ticket 1002 is wired to
        # ignore StatusId entirely, standing in for a payload whose field name
        # is wrong: the request succeeds and nothing changes.
        ignore_status = hit["Number"] == 1002
        # Reject a payload carrying anything this server has no business
        # sending, so the suite fails if the tool's scope ever widens quietly.
        allowed = {"ClientId", "StatusId", "UpdatedByName"}
        extra = set(body) - allowed
        if extra:
            return self.reply(400, fail(400, "Unexpected fields: %s" % ", ".join(sorted(extra))))
        if "ClientId" in body:
            hit["ClientId"] = body["ClientId"]
        if "StatusId" in body and not ignore_status:
            st = by_id.get(body["StatusId"])
            if st:
                hit["Status"] = {"Id": st["Id"], "Name": st["Name"]}
        return self.reply(200, env(hit))

    def do_GET(self):
        if not self.authorised():
            return
        u = urlparse(self.path)
        path, q = u.path, parse_qs(u.query)

        # Test-only endpoints for the retry logic.
        # A DELETE-only route: exists, but rejects GET with 405. This is how
        # /v1/tickets/{id}/time-entries/{id} actually behaves, and the 404-vs-405
        # distinction is the only way to map an undocumented surface.
        if re.fullmatch(r"/v1/tickets/[^/]+/time-entries/[^/]+", path):
            self.send_response(405)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if path == "/v1/flaky":
            Handler.flaky += 1
            if Handler.flaky <= 2:
                return self.reply(429, {"error": "Rate limit exceeded",
                                        "message": "Too many requests",
                                        "retry_after": "1s"})
            return self.reply(200, env([{"Ok": True}]))
        if path == "/v1/boom":
            return self.reply(500, {"error": "server fault"})

        if path == "/v1/tickets/statuses":
            return self.reply(200, env(STATUSES))

        if path == "/v1/organization/users":
            rows, pag = paginate(USERS, q)
            return self.reply(200, env(rows, pag))

        if path == "/v1/organization/groups":
            rows, pag = paginate(GROUPS, q)
            return self.reply(200, env(rows, pag))

        if path == "/v1/clients":
            rows, pag = paginate(CLIENTS, q)
            return self.reply(200, env(rows, pag))

        if path == "/v1/contacts":
            rows = CONTACTS
            if "ClientId" in q:               # singular only, as in real Gorelo
                rows = [c for c in rows if str(c["ClientId"]) == q["ClientId"][0]]
            rows, pag = paginate(rows, q)
            return self.reply(200, env(rows, pag))

        if path == "/v1/assets/agents":
            # ClientIds filtering arrived in the 2026-08-21 release. Before it
            # this endpoint took no filters at all.
            rows = AGENTS
            if "ClientIds" in q:
                want = set(q["ClientIds"][0].split(","))
                rows = [a for a in rows if str(a.get("ClientId")) in want]
            rows, pag = paginate(rows, q)
            return self.reply(200, env(rows, pag))

        m = re.fullmatch(r"/v1/tickets/([^/]+)/(comments|conversations|notes)", path)
        if m:
            if m.group(2) != "comments":
                return self.reply(404, fail(404, "Not found"))
            rows, pag = paginate(COMMENTS.get(m.group(1), []), q)
            return self.reply(200, env(rows, pag))

        m = re.fullmatch(r"/v1/tickets/([^/]+)", path)
        if m:
            hit = next((t for t in TICKETS if t["Id"] == m.group(1)), None)
            if hit:
                # Since 2026-08-21 the get-by-id returns MORE than the list
                # row: Description, a time and billing breakdown, Products,
                # BillingOverride, Shipments, linked assets and a Banner.
                # The list row deliberately does NOT carry these, so a tool
                # that renders time must be fetching the detail endpoint.
                detail = dict(hit)
                detail["Description"] = "<p>Detail body for %s</p>" % hit["DisplayNumber"]
                detail["Time"] = TICKET_TIME.get(hit["Id"], {
                    "ActualHours": 0.0, "AdjustedHours": 0.0,
                    "Breakdown": {
                        "Billable": {"ActualHours": 0.0, "AdjustedHours": 0.0},
                        "NotBillable": {"ActualHours": 0.0, "AdjustedHours": 0.0},
                        "NotBillableHidden": {"ActualHours": 0.0, "AdjustedHours": 0.0},
                    }})
                detail["Products"] = {"Count": 0, "TotalAmount": 0.0}
                detail["BillingOverride"] = {"ContractServiceId": None, "BillingRoleId": None,
                                             "WorkTypeId": None, "BillableStatus": None}
                detail["Shipments"] = []
                detail["Banner"] = ""
                return self.reply(200, env(detail))
            return self.reply(404, fail(404, "Ticket not found"))

        if path == "/v1/tickets":
            rows = TICKETS
            if "LeadAssigneeIds" in q:
                want = set(q["LeadAssigneeIds"][0].split(","))
                rows = [t for t in rows if str(t["LeadAssigneeId"]) in want]
            if "ClientIds" in q:
                want = set(q["ClientIds"][0].split(","))
                rows = [t for t in rows if str(t["ClientId"]) in want]
            if "Query" in q:
                # Documented: matches title, number and display number.
                needle = q["Query"][0].lower()
                rows = [t for t in rows
                        if needle in t["Title"].lower()
                        or needle == str(t["Number"])
                        or needle == t["DisplayNumber"].lower()]
            if "StatusIds" in q:
                want = set(q["StatusIds"][0].split(","))
                rows = [t for t in rows if str(t["Status"]["Id"]) in want]
            # AssistingAssigneeIds, AssigneeIds and WatcherIds are response
            # fields, not filters: accepted and ignored, as the real API does.
            rows, pag = paginate(rows, q)
            return self.reply(200, env(rows, pag))

        self.reply(404, fail(404, f"No route {path}"))

    def do_POST(self):
        if not self.authorised():
            return
        u = urlparse(self.path)
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        m = re.fullmatch(r"/v1/tickets/([^/]+)/comments", u.path)
        if m:
            # Enforce CreatePublicCommentCommand as documented: ConversationId
            # is rejected for Public and Private, and anything not in the
            # schema is a bug in the caller, not something to quietly accept.
            allowed = {"ConversationTypeId", "ConversationId", "Body",
                       "CreatedByName", "Attachments"}
            unknown = set(body) - allowed
            if unknown:
                return self.reply(400, fail(400, "Unknown fields: %s" % sorted(unknown)))
            if body.get("ConversationTypeId") in (1, 2) and "ConversationId" in body:
                return self.reply(400, fail(400, "ConversationId rejected for Public/Private"))
            POSTED.append({"ticket": m.group(1), "body": body})
            sys.stderr.write("POSTED to %s ConversationTypeId=%s\n"
                             % (m.group(1), body.get("ConversationTypeId")))
            sys.stderr.flush()
            return self.reply(200, env({"Id": "new-comment"}))
        self.reply(404, fail(404, "No such write path"))


if __name__ == "__main__":
    print("mock gorelo on 127.0.0.1:%d" % PORT, file=sys.stderr)
    print("  %d tickets, %d clients, %d agents" %
          (len(TICKETS), len(CLIENTS), len(AGENTS)), file=sys.stderr)
    print("  expected: %d unclosed led by user %d, +9 assisting, "
          "14 merged excluded, 2 unlisted-status" %
          (len(MINE_UNCLOSED_LEAD), ME), file=sys.stderr)
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
