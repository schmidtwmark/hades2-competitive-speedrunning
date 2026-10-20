#!/usr/bin/env bash
# Deploy the race server to Railway and expose it over a TCP proxy (the
# server speaks raw TCP, not HTTP). Idempotent: reuses the project/service if
# they exist. Prints "RAILWAY_ADDRESS=<host>:<port>" at the end.
#   scripts/railway-deploy.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT=hades2-ranked-race
SERVICE=race-server
PORT=7777
cd "$ROOT/server"

if ! railway list 2>/dev/null | grep -qx "  $PROJECT"; then
  railway init --name "$PROJECT"
fi
railway link --project "$PROJECT" >/dev/null 2>&1 || true
if ! railway service status --service "$SERVICE" >/dev/null 2>&1; then
  railway add --service "$SERVICE" --variables "PORT=$PORT" --variables "HOST=::"
fi
railway variable set --service "$SERVICE" PORT=$PORT "HOST=::" >/dev/null 2>&1 || true
# SKIP_UP=1: only (re)create the TCP proxy.
if [ "${SKIP_UP:-0}" != 1 ]; then
  railway up --service "$SERVICE" --ci -m "race server $(git -C "$ROOT" rev-parse --short HEAD)"
fi

# TCP proxy through Railway's public GraphQL API (no CLI command for it).
STATUS_JSON="$(railway status --json)"
python3 - "$STATUS_JSON" "$SERVICE" "$PORT" <<'PY'
import json, os, sys, urllib.request
status, service_name, port = json.loads(sys.argv[1]), sys.argv[2], int(sys.argv[3])
token = json.load(open(os.path.expanduser("~/.railway/config.json")))["user"]["token"]

def gql(query, variables):
    req = urllib.request.Request("https://backboard.railway.com/graphql/v2",
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                 # Railway's edge rejects urllib's default user agent with 403.
                 "User-Agent": "hades2-ranked-race-deploy/1"})
    out = json.load(urllib.request.urlopen(req, timeout=30))
    if out.get("errors"):
        raise SystemExit(f"railway api error: {out['errors']}")
    return out["data"]

env_id = None
for e in status.get("environments", {}).get("edges", []):
    if e["node"]["name"] == "production":
        env_id = e["node"]["id"]
service_id = None
for s in status.get("services", {}).get("edges", []):
    if s["node"]["name"] == service_name:
        service_id = s["node"]["id"]
if not (env_id and service_id):
    raise SystemExit(f"could not find environment/service ids in railway status: env={env_id} service={service_id}")

existing = gql("query($s:String!,$e:String!){ tcpProxies(serviceId:$s, environmentId:$e){ domain proxyPort applicationPort } }",
               {"s": service_id, "e": env_id})["tcpProxies"]
proxy = next((p for p in existing if p["applicationPort"] == port), None)
if not proxy:
    proxy = gql("mutation($i:TCPProxyCreateInput!){ tcpProxyCreate(input:$i){ domain proxyPort applicationPort } }",
                {"i": {"serviceId": service_id, "environmentId": env_id, "applicationPort": port}})["tcpProxyCreate"]
print(f"RAILWAY_ADDRESS={proxy['domain'].rstrip('.')}:{proxy['proxyPort']}")
PY
