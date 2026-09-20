#!/usr/bin/env bash
# Prints the Rocket.Chat releases that are currently supported, newest support
# window first.
#
# Rocket.Chat publishes this as a signed JWT. Only the payload is read here;
# the signature is not verified, because this is advisory output shown to an
# operator, not an authorisation decision. Treat the result as a hint to check
# against the release notes, not as proof.
#
# Exit status is 2 if the feed could not be reached, so callers can distinguish
# "unsupported" from "unknown".
#
# With an argument, checks that one version and exits 0 if it is supported.

set -euo pipefail

FEED='https://releases.rocket.chat/v2/server/supportedVersions'
WANT="${1:-}"

payload="$(curl -fsS --max-time 15 "$FEED" 2>/dev/null)" || {
  echo "could not reach ${FEED}" >&2
  exit 2
}

printf '%s' "$payload" | WANT="$WANT" python3 -c '
import sys, json, base64, os, datetime

want = os.environ.get("WANT", "")

try:
    signed = json.load(sys.stdin)["signed"]
    body = signed.split(".")[1]
    body += "=" * (-len(body) % 4)
    data = json.loads(base64.urlsafe_b64decode(body))
except Exception as exc:
    print(f"could not parse the supported-versions feed: {exc}", file=sys.stderr)
    sys.exit(2)

today = datetime.datetime.now(datetime.timezone.utc)
rows = []
for v in data.get("versions", []):
    version = v.get("version", "")
    if "-" in version:      # skip develop and rc builds
        continue
    exp = v.get("expiration", "")
    try:
        when = datetime.datetime.fromisoformat(exp.replace("Z", "+00:00"))
    except ValueError:
        continue
    if when < today:
        continue
    rows.append((when, version))

if not rows:
    print("the feed listed no currently supported release", file=sys.stderr)
    sys.exit(2)

rows.sort(reverse=True)

if want:
    supported = [v for _, v in rows]
    if want in supported:
        print(f"{want} is supported")
        sys.exit(0)
    print(f"{want} is NOT in the supported list", file=sys.stderr)
    print("currently supported: " + ", ".join(sorted(set(supported))), file=sys.stderr)
    sys.exit(1)

print("  Rocket.Chat releases currently supported (longest window first):")
seen = set()
for when, version in rows:
    series = version.rsplit(".", 1)[0]
    if series in seen:
        continue
    seen.add(series)
    days = (when - today).days
    print(f"    {version:<10} supported until {when.date()}  ({days} days)")
'
