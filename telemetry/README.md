# Telemetry backend

The self-hosted [Aptabase](https://github.com/aptabase/aptabase) instance behind
`telemetry.vocahq.com`, which is where the anonymous usage counters described in
[`docs/privacy.md`](../docs/privacy.md) land.

This directory exists for one reason: **`docs/privacy.md` makes claims about a
server, and a claim about a server that nobody can inspect is exactly the vendor
promise self-hosting was supposed to replace.** The deployment lives here so the
configuration is readable by anyone who wants to check what we say against what
we run.

> [!IMPORTANT]
> `docker-compose.yml` here is a **template, not yet the running configuration.**
> The live instance was stood up before this directory existed, so the
> authoritative version is on the server. Reconcile them before treating this
> file as documentation of anything — see [Bringing the real config
> in](#bringing-the-real-config-in). Until that is done, this file describes what
> we intend to run rather than what we run, and the difference is the whole point
> of the directory.

## What runs

Three containers, which is the main reason Aptabase was chosen over PostHog's
eight-service stack (`docs/decisions.md:53`):

| Container | Role |
| --- | --- |
| `aptabase` | Ingest (`POST /api/v0/events`) and the dashboard, same host |
| `aptabase_db` | PostgreSQL — accounts, apps, the app key registry |
| `aptabase_events_db` | ClickHouse — the events themselves |

Ingest and dashboard share a hostname. The clients only ever speak to
`/api/v0/events`; see `TelemetryConfig` on either platform.

## Verifying what `docs/privacy.md` claims

Four things need to be established and dated. Each is a claim currently sitting
unverified in the table in [`docs/privacy.md`](../docs/privacy.md). Run these,
then replace that table's status column with the date it was checked.

Everything below assumes you are on the host, in this directory.

### 1. No raw IP is persisted

The load-bearing one. Aptabase needs the client address transiently to compute
its daily rotating user hash, and states that it does not store it. Check rather
than believe.

Written as discovery rather than confirmation on purpose — the point of an audit
is to look at what is there, not to confirm the shape you already assumed:

```sh
docker compose exec aptabase_events_db clickhouse-client --query "SHOW DATABASES"
docker compose exec aptabase_events_db clickhouse-client --query "SHOW TABLES FROM aptabase"
docker compose exec aptabase_events_db clickhouse-client --query "DESCRIBE TABLE aptabase.events" --format PrettyCompact
```

Read the column list yourself. Then look at a real row whole, rather than the
columns you thought to ask for:

```sh
docker compose exec aptabase_events_db clickhouse-client \
  --query "SELECT * FROM aptabase.events ORDER BY timestamp DESC LIMIT 1" --format Vertical
```

And sweep every string column for anything address-shaped, so a field nobody
thought about cannot hide:

```sh
docker compose exec aptabase_events_db clickhouse-client --query "
  SELECT name, type FROM system.columns
  WHERE database = 'aptabase' AND table = 'events'
    AND (name ILIKE '%ip%' OR name ILIKE '%addr%' OR name ILIKE '%host%'
         OR name ILIKE '%remote%' OR name ILIKE '%client%')"
```

An empty result plus a clean sample row is the pass condition. A `country_code`
or `region_name` column is expected and is not a raw address — Aptabase derives
coarse geography before discarding the IP. Note in `docs/privacy.md` that those
columns exist if they do, because "no raw IP" and "no location at all" are
different claims and only the first one is ours to make.

### 2. Retention actually expires

`docs/privacy.md` says events age out. Read the clause rather than assuming the
default:

```sh
docker compose exec aptabase_events_db clickhouse-client \
  --query "SELECT engine_full FROM system.tables WHERE database='aptabase' AND name='events'" \
  --format Vertical
```

If there is no `TTL` in the output, there is no retention limit and the sentence
in `docs/privacy.md` is false. The intended value is 180 days — long enough for
a beta's seasonality, short enough to state publicly without hedging:

```sh
docker compose exec aptabase_events_db clickhouse-client \
  --query "ALTER TABLE aptabase.events MODIFY TTL timestamp + INTERVAL 180 DAY"
```

Re-run the `engine_full` query afterwards and paste the result into the commit
message. Applying a TTL to an existing table starts a background merge; it is not
instant, and `SELECT count() FROM aptabase.events` will keep counting old rows
for a while.

### 3. The proxy does not log what the server declines to store

Aptabase not storing the address is worthless if nginx writes it to disk beside
it. For the ingest location specifically:

```nginx
location /api/v0/events {
    access_log off;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:8000;
}
```

`X-Forwarded-For` is deliberately passed — this is the opposite of the usual
advice, and it is what makes the daily hash work at all. `access_log off` is what
keeps it from outliving the request. Check the deployed config, not this snippet.

### 4. Rate limit the ingest path

Not in place. The ingest key ships inside every binary and cannot be secret, so
the exposure is somebody posting junk to skew the beta numbers — a data-quality
problem, not a privacy one, but a real one:

```nginx
limit_req_zone $binary_remote_addr zone=ingest:10m rate=30r/m;

location /api/v0/events {
    limit_req zone=ingest burst=20 nodelay;
    access_log off;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:8000;
}
```

`limit_req_zone` keys on the address, which nginx holds in memory for the
duration of the request either way; it writes nothing to disk. Size the rate
against real client behaviour before applying it: both clients debounce a flush
by five seconds and batch up to `TelemetryConfig.maxBatch` events per request, so
a single active user is nowhere near 30 requests a minute.

## Confirming events actually arrive

Two things were learned against the live instance and are worth keeping in front
of whoever next tries to confirm this works.

**A `200` from the ingest does not mean anything was stored.** Measured: a bogus
`App-Key` returns 200, *no* `App-Key` returns 200, and only malformed JSON
returns 400. The endpoint answers 200 to anything well-formed and silently drops
events whose key does not map to a registered app. The clients drop a batch on
4xx too, so an emptied client queue is not evidence either. **Every client-side
signal available is indistinguishable between "stored" and "silently
discarded"** — the only authority is this server: ClickHouse rows, or the
dashboard.

```sh
docker compose exec aptabase_events_db clickhouse-client \
  --query "SELECT event_name, count() FROM aptabase.events
           WHERE timestamp > now() - INTERVAL 1 HOUR GROUP BY event_name"
```

**The dashboard splits Debug and Release, and the default is easy to misread.**
An orange `Debug Data` ribbon and a bug/rocket toggle in the top right decide
which bucket you are looking at, and the split comes purely from the `isDebug`
flag in the payload. Both clients send `isDebug: false` in release builds and
transmit nothing at all from debug builds, so **every real event is in Release**
— while a hand-rolled probe sent with `isDebug: true` lands in the other bucket
and looks like proof the pipeline works. Check which mode is selected before
concluding anything.

## Bringing the real config in

The instance predates this directory, so do this before trusting anything here:

```sh
# On the host, from wherever the live stack is defined:
docker compose config > /tmp/telemetry-live.yml
```

`docker compose config` resolves every variable, so **the output contains the
Postgres password, the ClickHouse password and `AUTH_SECRET`.** Diff it against
`docker-compose.yml` here, port the structural differences, and keep every secret
in the untracked `.env` — see [Secrets](#secrets). Do not commit the resolved
output.

Then delete the warning at the top of this file, because it will have stopped
being true.

## Secrets

Nothing secret belongs in this directory. `docker-compose.yml` reads from a
`.env` file that is gitignored:

```
POSTGRES_PASSWORD=
CLICKHOUSE_PASSWORD=
AUTH_SECRET=
SMTP_HOST=
SMTP_PORT=
SMTP_USERNAME=
SMTP_PASSWORD=
SMTP_FROM_ADDRESS=
```

`AUTH_SECRET` signs dashboard sessions. Rotating it logs everyone out and is
otherwise harmless.

The **ingest key is not in this list and is not a secret** — `A-SH-3275173609`
is committed into both apps deliberately, because it ships inside every binary
and is extractable from any store download. `docs/privacy.md` explains the
reasoning. Do not "fix" this by moving it to an environment variable; that would
hide it from contributors and from nobody else.

## Pinning

`ghcr.io/aptabase/aptabase:main` moves whenever upstream does, and a floating tag
on the service that receives user data is a bad place to discover a schema
change. Pin by digest and upgrade deliberately:

```sh
docker buildx imagetools inspect ghcr.io/aptabase/aptabase:main --format '{{.Manifest.Digest}}'
```

F-Droid reproducibility does not touch any of this — that is the Android native
build, not the backend — but the same instinct applies: nothing here should
change because a registry moved.

## Upgrading

1. Read Aptabase's release notes for schema migrations.
2. Snapshot Postgres (`docker compose exec aptabase_db pg_dump -U aptabase aptabase | gzip > …`).
3. Update the digest, `docker compose up -d`, watch `docker compose logs -f aptabase`.
4. Re-run step 1 of [the privacy verification](#verifying-what-docsprivacymd-claims). A migration is exactly when a column
   that stores an address could appear, and the whole claim rests on nobody
   having checked in a year.

## What this instance is not

It is not on the dictation path. The gateway (`gateway/`) is a separate service
with a separate hostname, a real bearer token and the user's audio; this one has
counters and no credentials worth stealing. A failure here must never surface in
either app — both clients fail closed and drop events rather than showing a user
an error about a feature they did not ask for.

## Still to do

Carried over from the telemetry rollout plan, which this directory replaces.
Ordered by what it costs to be wrong:

1. **The audit above**, and the TTL, and the ingest rate limit — every one of
   them is a claim already sitting in a public document.
2. **Console paperwork.** The in-repo half is done: the iOS app target's
   `PrivacyInfo.xcprivacy` declares Product Interaction, not linked, not
   tracking, analytics purpose, and the keyboard and Live Activity manifests are
   correctly empty. What is left is the App Store Connect nutrition label and
   Play Data safety, including the "users can choose whether this data is
   collected" checkbox that only the in-app toggle makes truthfully tickable.
   This gates the next release rather than a later one.
3. **Read `model_id` and `quality`.** The dictation events carry which shipped
   model transcribed and at what accuracy setting, and nothing queries them yet.
   An event nobody reads is a cost with no benefit — it widened the payload and
   buys nothing until there is a saved query for failure rate and duration bucket
   grouped by `model_id`, on-device rows only.
4. **Keyboard `insertion_skipped` events (later).** The hardest failure in the
   product to reproduce, and the one thing v1 knowingly gave up. The constraint
   is fixed: the iOS extension writes to the shared App Group queue and never
   opens a socket, the containing app stays the only sender, and the keyboard's
   `NSPrivacyCollectedDataTypes` is revisited only then. A Full Access keyboard
   that can open a socket is the scariest thing this product could ship,
   whatever is actually in the packet.

Still open: whether to add a `channel` prop to tell TestFlight from the App
Store. The case against it has not weakened — it is one more correlating bit on
a small population, and `appVersion` already separates most of what it would.
