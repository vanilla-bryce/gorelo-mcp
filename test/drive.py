#!/usr/bin/env python3
"""Drive the MCP server over real JSON-RPC frames on stdin/stdout.

Start the mock first, in another terminal:

    python3 mock_gorelo.py

Then:

    python3 drive.py                 # run the built-in checks
    python3 drive.py calls.json      # run a list of tool calls from a file

With no argument it runs an assertion suite covering the cases that have
actually broken: merged tickets, unlisted statuses, assisting assignees,
watchers, closed-ticket exclusion, ticket lookup by number, deleted comments,
the write guards, and the protocol edge cases.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "gorelo-mcp-server.rb")

ENV = dict(os.environ)
ENV.update({
    "GORELO_API_KEY": os.environ.get("KEY", "test-key-123"),
    "GORELO_BASE_URL": "http://127.0.0.1:8899",
    "GORELO_MY_EMAIL": "sam@example.com",
    "GORELO_ALLOW_WRITES": os.environ.get("WRITES", "false"),
    "HOME": os.path.join(HERE, "_tmp_home"),
})
os.makedirs(ENV["HOME"], exist_ok=True)
WRITE_LOG = os.path.join(ENV["HOME"], ".gorelo-mcp-writes.jsonl")
if os.path.exists(WRITE_LOG):
    os.remove(WRITE_LOG)


class Server:
    def __init__(self):
        self.p = subprocess.Popen(
            ["ruby", SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=ENV, text=True, bufsize=1)
        self.n = 0
        self.rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                  "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                             "clientInfo": {"name": "drive.py", "version": "1"}}})
        self.notify({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def rpc(self, msg):
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()
        line = self.p.stdout.readline()
        if not line:
            raise SystemExit("server closed stdout - is the mock running?")
        return json.loads(line)

    def notify(self, msg):
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()

    def call(self, name, **args):
        self.n += 1
        r = self.rpc({"jsonrpc": "2.0", "id": 100 + self.n, "method": "tools/call",
                      "params": {"name": name, "arguments": args}})
        return r["result"]["content"][0]["text"]

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=30)
        return self.p.stderr.read()


PASS, FAIL = 0, 0


def check(label, condition, detail=""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print("  ok   %s" % label)
    else:
        FAIL += 1
        print("  FAIL %s   %s" % (label, detail))


def run_suite():
    s = Server()

    tools = s.rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})["result"]["tools"]
    names = [t["name"] for t in tools]
    check("8 tools advertised", len(tools) == 8, names)
    check("only the comment tool is not read-only",
          [t["name"] for t in tools if not t["annotations"]["readOnlyHint"]]
          == ["gorelo_add_ticket_comment"])

    print("\ncounting")
    everything = s.call("gorelo_list_tickets", status="all", limit=300)
    check("merged tickets excluded and named", "14 merged tickets excluded" in everything,
          everything.splitlines()[:4])
    check("unlisted status is reported, not dropped",
          "Waiting Vendor" in everything and "did not list" in everything)
    check("assisting assignees counted", "9 as assisting assignee" in everything)

    watch = s.call("gorelo_list_tickets", status="open", limit=300)
    check("watcher-only ticket excluded", "Watching only" not in watch)
    check("closed-assist tickets excluded", "Closed assist" not in watch)

    closed = s.call("gorelo_list_tickets", status="closed", limit=5)
    check("closed view skips the assisting sweep", "as assisting assignee" not in closed)

    opted_out = s.call("gorelo_list_tickets", status="all", include_assisting=False, limit=5)
    check("include_assisting=false honoured", "as assisting assignee" not in opted_out)

    print("\nfiltering")
    solved = s.call("gorelo_list_tickets", status="solved", limit=50, include_reasons=True)
    check("solved base includes Billing and Standing",
          "Billing" in solved and "Standing Ticket" in solved)
    check("status reason JSON is unwrapped", "needs invoicing" in solved and
          '"updatedById"' not in solved)

    stale = s.call("gorelo_list_tickets", status="all", stale_days=1000, limit=5)
    check("stale_days filters everything out", "Showing 0 of 0" in stale)

    two_terms = s.call("gorelo_search_clients", term="adventure,awx")
    check("comma-separated client terms are OR-ed",
          "Adventure Works" in two_terms and "AWX Holdings" in two_terms)

    print("\nticket lookup (no API support for number or search)")
    open_one = s.call("gorelo_get_ticket", ticket="G-1000")
    check("open ticket found by number", "Open work item 1" in open_one)
    check("comments render with author", "Dana Ellis" in open_one)
    check("private comment flagged", "PRIVATE" in open_one)
    check("gorelo truncation flagged", "TRUNCATED" in open_one)
    check("attachments counted", "1 attachment(s)" in open_one)
    check("DELETED comment body withheld",
          "SENSITIVE-MUST-NOT-BE-PRINTED" not in open_one and "deleted in Gorelo" in open_one)

    closed_one = s.call("gorelo_get_ticket", ticket="G-1060", include_comments=False)
    check("merged/other ticket found via widened index", "G-1060" in closed_one)

    missing = s.call("gorelo_get_ticket", ticket="G-999999", include_comments=False)
    check("unknown number fails clearly", "No ticket" in missing)

    print("\nassets")
    assets = s.call("gorelo_list_assets", stale_days=100, limit=50)
    check("stale devices found", "WS-000" in assets)
    fresh = s.call("gorelo_list_assets", client="Northwind", limit=50)
    check("client filter applied locally", "WS-001" in fresh and "WS-011" not in fresh)

    print("\nwrite guards (writes disabled)")
    check("write refused when disabled",
          "Writes are disabled" in s.call("gorelo_add_ticket_comment",
                                          ticket="G-1000", body="x", confirm=True))

    print("\nprobe")
    check("probe refuses non-/v1 paths",
          "Refused" in s.call("gorelo_api_probe", path="/etc/passwd"))
    check("probe returns pagination",
          "Pagination" in s.call("gorelo_api_probe", path="/v1/tickets", chars=300))

    print("\nprotocol")
    check("ping", s.rpc({"jsonrpc": "2.0", "id": 900, "method": "ping"})["result"] == {})
    check("unknown method is -32601",
          s.rpc({"jsonrpc": "2.0", "id": 901,
                 "method": "no/such"})["error"]["code"] == -32601)
    check("unknown tool is an isError result, not a protocol error",
          s.rpc({"jsonrpc": "2.0", "id": 902, "method": "tools/call",
                 "params": {"name": "nope", "arguments": {}}})["result"]["isError"])
    s.notify({"jsonrpc": "2.0", "method": "notifications/something"})
    s.p.stdin.write("this is not json\n")
    s.p.stdin.flush()
    check("survives a malformed line",
          s.rpc({"jsonrpc": "2.0", "id": 903, "method": "ping"})["result"] == {})

    stderr = s.close()

    print("\nwrites ENABLED")
    ENV["GORELO_ALLOW_WRITES"] = "true"
    s2 = Server()
    check("confirm is required",
          "confirm" in s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                               body="note", confirm=False))
    check("empty body refused",
          "empty" in s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                             body="   ", confirm=True))
    first = s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                    body="Intake review note.", confirm=True)
    check("internal comment posted", "internal" in first and "Posted" in first)
    again = s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                    body="Intake review note.", confirm=True)
    check("duplicate within 24h refused", "Refused" in again)
    visible = s2.call("gorelo_add_ticket_comment", ticket="G-1000",
                      body="Client visible note.", visibility="client", confirm=True)
    check("client-visible comment is labelled loudly", "CLIENT-VISIBLE" in visible)
    s2.close()
    ENV["GORELO_ALLOW_WRITES"] = "false"

    print("\n%d passed, %d failed" % (PASS, FAIL))
    if FAIL:
        print("\nserver stderr:\n" + stderr[-2000:])
    return 1 if FAIL else 0


def run_file(path):
    s = Server()
    for call in json.load(open(path)):
        print("\n" + "=" * 78)
        print("%s %s" % (call["name"], json.dumps(call.get("arguments", {}))))
        print("=" * 78)
        print(s.call(call["name"], **call.get("arguments", {})))
    s.close()
    return 0


if __name__ == "__main__":
    sys.exit(run_file(sys.argv[1]) if len(sys.argv) > 1 else run_suite())
