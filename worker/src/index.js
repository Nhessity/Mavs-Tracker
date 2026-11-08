// Mavs Game Alerts proxy: fetches ESPN's huge NBA scoreboard and returns a tiny
// JSON payload (~300 bytes) for the Dallas Mavericks game, so the watch can parse it.

const ESPN_URL =
  "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard";
const DEFAULT_TEAM = "DAL";

export default {
  async fetch(request, env) {
    // Optional shared secret: if an API_KEY secret is set on the Worker, require it.
    if (env.API_KEY && request.headers.get("x-api-key") !== env.API_KEY) {
      return json({ error: "Unauthorized" }, 401);
    }

    // Optional ?team=GS for testing with another team's live game (ESPN abbreviation).
    const param = new URL(request.url).searchParams.get("team");
    const team = param && /^[A-Za-z]{2,4}$/.test(param)
      ? param.toUpperCase()
      : DEFAULT_TEAM;
    try {
      // Cache the ESPN response at Cloudflare's edge for 15s to be polite to ESPN.
      const res = await fetch(ESPN_URL, {
        cf: { cacheTtl: 15, cacheEverything: true },
      });
      if (!res.ok) {
        return json({ error: `ESPN returned ${res.status}` }, 502);
      }
      const data = await res.json();
      return json(extractMavsGame(data, team));
    } catch (err) {
      return json({ error: "Failed to fetch or parse ESPN data" }, 502);
    }
  },
};

function extractMavsGame(data, team) {
  const events = Array.isArray(data?.events) ? data.events : [];

  for (const ev of events) {
    const comp = ev?.competitions?.[0];
    const competitors = comp?.competitors;
    if (!Array.isArray(competitors)) continue;

    const mavs = competitors.find((c) => c?.team?.abbreviation === team);
    if (!mavs) continue;

    const opp = competitors.find((c) => c !== mavs);
    const home = competitors.find((c) => c?.homeAway === "home");
    const away = competitors.find((c) => c?.homeAway === "away");
    const status = ev.status ?? comp.status ?? {};

    return {
      found: true,
      gameId: ev.id ?? null,
      state: status.type?.state ?? null, // "pre" | "in" | "post"
      statusName: status.type?.name ?? null, // e.g. "STATUS_HALFTIME"
      period: status.period ?? null, // 1-4, 5+ = overtime
      clock: status.displayClock ?? null, // time remaining in the period, e.g. "7:42"
      startTime: toEpochSeconds(ev.date ?? comp.date), // scheduled tip-off, UTC epoch seconds
      detail: status.type?.shortDetail ?? null, // e.g. "Q2 7:42", "Halftime", "Final", start time when "pre"
      mavsHomeAway: mavs.homeAway ?? null, // "home" | "away"
      opponent: opp?.team?.shortDisplayName ?? null, // e.g. "Pistons"
      opponentAbbr: opp?.team?.abbreviation ?? null, // e.g. "DET"
      home: teamInfo(home),
      away: teamInfo(away),
      mavsScore: toScore(mavs.score),
      opponentScore: toScore(opp?.score),
    };
  }

  return { found: false };
}

function toEpochSeconds(iso) {
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? null : Math.floor(ms / 1000);
}

function teamRecord(c) {
  const recs = Array.isArray(c?.records) ? c.records : [];
  const overall = recs.find((r) => r?.type === "total") ?? recs[0];
  return overall?.summary ?? null;
}

function teamInfo(c) {
  return {
    abbr: c?.team?.abbreviation ?? null,
    name: c?.team?.shortDisplayName ?? null,
    record: teamRecord(c), // overall W-L, e.g. "5-3"
    score: toScore(c?.score),
  };
}

// ESPN returns scores as strings (and may omit them before tip-off).
function toScore(v) {
  const n = parseInt(v, 10);
  return Number.isNaN(n) ? null : n;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": "private, max-age=10",
    },
  });
}
