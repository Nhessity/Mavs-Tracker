import Toybox.Attention;
import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

const WORKER_BASE = "https://mavs-game-alerts.mavs-game-alerts.workers.dev/";

// ---- Test settings ----
// TEAM_ABBR: "DAL" for real use. Set to another ESPN abbreviation (e.g. "GS") to
// test against that team's live game.
const TEAM_ABBR = "DAL";
// USE_MOCK: true = fake game that advances every few seconds (no network).
const USE_MOCK = false;

const POLL_MS = 60000;
const MOCK_POLL_MS = 5000;

class MavsTrackerView extends WatchUi.View {

    private var _timer as Timer.Timer;
    private var _timerOn as Boolean = false;
    private var _visible as Boolean = false;
    private var _busy as Boolean = false;   // prevents overlapping requests

    // Previous observed quarter. null = nothing observed yet (no alert on first read).
    private var _lastPeriod as Number or Null = null;

    // Display strings
    private var _opponent as String = "";
    private var _status as String = "";
    private var _score as String = "";
    private var _msg as String = "Loading...";
    private var _mockTick as Number = 0;

    function initialize() {
        View.initialize();
        _timer = new Timer.Timer();
    }

    function onShow() as Void {
        _visible = true;
        refresh();
    }

    function onHide() as Void {
        _visible = false;
        stopTimer();
    }

    // ---------- Vibration ----------

    function testVibrate() as Void {
        vibrate();
    }

    private function vibrate() as Void {
        if (Attention has :vibrate) {
            var vibe = [new Attention.VibeProfile(100, 600)];
            Attention.vibrate(vibe);
        }
    }

    // ---------- Polling ----------

    private function startTimer() as Void {
        if (!_timerOn) {
            _timer.start(method(:refresh), USE_MOCK ? MOCK_POLL_MS : POLL_MS, true);
            _timerOn = true;
        }
    }

    private function stopTimer() as Void {
        if (_timerOn) {
            _timer.stop();
            _timerOn = false;
        }
    }

    function refresh() as Void {
        if (_busy) {
            return;
        }
        if (USE_MOCK) {
            onResponse(200, mockData());
            return;
        }
        _busy = true;
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        var url = WORKER_BASE + "?team=" + TEAM_ABBR;
        Communications.makeWebRequest(url, null, options, method(:onResponse));
    }

    function onResponse(code as Number, data as Dictionary or String or Null) as Void {
        _busy = false;

        if (code != 200 || !(data instanceof Dictionary)) {
            _msg = "Unavailable (" + code.toString() + ")";
            WatchUi.requestUpdate();
            return;
        }

        var found = data["found"];
        if (!(found instanceof Boolean) || !found) {
            _opponent = "";
            _status = "";
            _score = "";
            _msg = "No Mavs game today";
            stopTimer();            // nothing relevant to poll
            WatchUi.requestUpdate();
            return;
        }

        _msg = "";
        parseGame(data);
        if (_visible) {
            startTimer();           // no-op if already running (stopped again on "post")
        }
        WatchUi.requestUpdate();
    }

    // ---------- Mock data (USE_MOCK) ----------
    // Tick 0 = pre-game, 1-3 = Q1, 4-6 = Q2, 7-9 = Q3, 10-12 = Q4, 13 = final, then repeats.

    private function mockData() as Dictionary {
        var t = _mockTick;
        var state = "in";
        var period = 0;
        var detail = "7:30 PM";
        if (t == 0) {
            state = "pre";
        } else if (t >= 13) {
            state = "post";
            period = 4;
            detail = "Final";
        } else {
            period = (t - 1) / 3 + 1;
        }
        _mockTick = (t >= 13) ? 0 : t + 1;
        return {
            "found" => true,
            "state" => state,
            "period" => period,
            "clock" => "6:30",
            "detail" => detail,
            "mavsHomeAway" => "home",
            "opponent" => "Mockers",
            "opponentAbbr" => "MCK",
            "mavsScore" => t * 4,
            "opponentScore" => t * 3 + 2
        };
    }

    // ---------- Parsing (Worker returns a flat dictionary) ----------

    private function parseGame(d as Dictionary) as Void {
        // Opponent + home/away
        var prefix = "away".equals(d["mavsHomeAway"]) ? "@ " : "vs ";
        var oppName = "TBD";
        if (d["opponent"] != null) {
            oppName = d["opponent"].toString();
        } else if (d["opponentAbbr"] != null) {
            oppName = d["opponentAbbr"].toString();
        }
        _opponent = prefix + oppName;

        // Score
        var mavsScore = d["mavsScore"];
        var oppScore = d["opponentScore"];
        _score = "";
        if (mavsScore instanceof Number && oppScore instanceof Number) {
            var oppAbbr = (d["opponentAbbr"] != null) ? d["opponentAbbr"].toString() : "OPP";
            _score = TEAM_ABBR + " " + mavsScore.toString()
                + " - " + oppScore.toString() + " " + oppAbbr;
        }

        // Status / quarter
        var state = (d["state"] != null) ? d["state"].toString() : "";
        var period = null;
        if (d["period"] instanceof Number) {
            period = d["period"];
        }
        var clock = (d["clock"] != null) ? d["clock"].toString() : "";
        var detail = (d["detail"] != null) ? d["detail"].toString() : "";

        if (state.equals("in") && period != null) {
            _status = periodLabel(period) + " " + clock;
        } else if (state.equals("post")) {
            _status = "Final";
            stopTimer();
        } else if (detail.length() > 0) {
            _status = detail;       // e.g. scheduled start time
        } else {
            _status = "Scheduled";
        }

        detectQuarterChange(state, period);
    }

    private function periodLabel(p as Number) as String {
        if (p <= 4) {
            return "Q" + p.toString();
        }
        return "OT" + (p - 4).toString();
    }

    // ---------- Event detection ----------

    private function detectQuarterChange(state as String, period as Number or Null) as Void {
        if (state.equals("pre")) {
            _lastPeriod = 0;        // so Q1 tip-off counts as a new quarter
            return;
        }
        if (!state.equals("in") || period == null) {
            return;
        }
        if (_lastPeriod != null && period > _lastPeriod) {
            vibrate();
        }
        _lastPeriod = period;       // baseline silently if first observation
    }

    // ---------- UI ----------

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var just = Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER;

        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 20 / 100, Graphics.FONT_XTINY, "Mavs Game Alerts", just);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (_opponent.length() > 0) {
            dc.drawText(w / 2, h * 38 / 100, Graphics.FONT_MEDIUM, _opponent, just);
            dc.drawText(w / 2, h * 55 / 100, Graphics.FONT_SMALL, _status, just);
            dc.drawText(w / 2, h * 70 / 100, Graphics.FONT_SMALL, _score, just);
        }
        if (_msg.length() > 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * (_opponent.length() > 0 ? 84 : 50) / 100,
                Graphics.FONT_SMALL, _msg, just);
        }
    }
}
