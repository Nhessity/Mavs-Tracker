import Toybox.Attention;
import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

// WORKER_BASE and WORKER_KEY live in source/Config.mc (git-ignored).
// Copy source/Config.mc.example to source/Config.mc and fill them in.

// ---- Test settings ----
// TEAM_ABBR: "DAL" for real use. Set to another ESPN abbreviation (e.g. "GS") to
// test against that team's live game.
const TEAM_ABBR = "DAL";
// USE_MOCK: true = fake game that advances every few seconds (no network).
const USE_MOCK = false;

const POLL_MS = 60000;
const MOCK_POLL_MS = 5000;
const WAKE_REFRESH_MIN_MS = 20000;  // don't refetch on wrist-raise more often than this

class MavsTrackerView extends WatchUi.View {

    private var _timer as Timer.Timer;
    private var _timerOn as Boolean = false;
    private var _busy as Boolean = false;   // prevents overlapping requests
    private var _lastRequestMs as Number = -100000;

    // Previous observed quarter. null = nothing observed yet (no alert on first read).
    private var _lastPeriod as Number or Null = null;

    // Display strings
    private var _hasGame as Boolean = false;
    private var _status as String = "";
    private var _awayAbbr as String = "";
    private var _homeAbbr as String = "";
    private var _awayRec as String = "";
    private var _homeRec as String = "";
    private var _awayScore as String = "";
    private var _homeScore as String = "";
    private var _msg as String = "Loading...";
    private var _updated as String = "";   // time of last successful poll

    private var _mockTick as Number = 0;

    function initialize() {
        View.initialize();
        _timer = new Timer.Timer();
    }

    // NOTE: onHide intentionally does NOT stop the timer. When the screen sleeps
    // between wrist raises, polling (and quarter alerts) must keep running.
    function onShow() as Void {
        if (System.getTimer() - _lastRequestMs > WAKE_REFRESH_MIN_MS) {
            refresh();
        }
    }

    // ---------- Vibration ----------

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
        _lastRequestMs = System.getTimer();
        if (USE_MOCK) {
            onResponse(200, mockData());
            return;
        }
        _busy = true;
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
        };
        if (WORKER_KEY.length() > 0) {
            options[:headers] = {"x-api-key" => WORKER_KEY};
        }
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

        _updated = formatTime(Time.now().value());

        var found = data["found"];
        if (!(found instanceof Boolean) || !found) {
            _hasGame = false;
            _status = "";
            _msg = "No Mavs game today";
            stopTimer();            // nothing relevant to poll
            WatchUi.requestUpdate();
            return;
        }

        _msg = "";
        if (parseGame(data)) {
            startTimer();           // no-op if already running
        } else {
            stopTimer();            // game is final
        }
        WatchUi.requestUpdate();
    }

    // ---------- Time formatting (device local time) ----------

    private function formatTime(epoch as Number) as String {
        var info = Time.Gregorian.info(new Time.Moment(epoch), Time.FORMAT_SHORT);
        var m = info.min;
        var mm = (m < 10) ? "0" + m.toString() : m.toString();
        if (System.getDeviceSettings().is24Hour) {
            return info.hour.toString() + ":" + mm;
        }
        var h12 = info.hour % 12;
        if (h12 == 0) {
            h12 = 12;
        }
        return h12.toString() + ":" + mm + ((info.hour >= 12) ? " PM" : " AM");
    }

    // ---------- Mock data (USE_MOCK) ----------
    // Tick 0 = pre-game, 1-3 = Q1, 4-6 = Q2, 7 = halftime, 8-10 = Q3, 11-13 = Q4, 14 = final, then repeats.

    private function mockData() as Dictionary {
        var t = _mockTick;
        var state = "in";
        var period = 0;
        var halftime = false;
        if (t == 0) {
            state = "pre";
        } else if (t >= 14) {
            state = "post";
            period = 4;
        } else if (t == 7) {
            period = 2;
            halftime = true;
        } else if (t < 7) {
            period = (t - 1) / 3 + 1;
        } else {
            period = (t - 8) / 3 + 3;
        }
        _mockTick = (t >= 14) ? 0 : t + 1;
        return {
            "found" => true,
            "state" => state,
            "statusName" => halftime ? "STATUS_HALFTIME" : "STATUS_IN_PROGRESS",
            "period" => period,
            "clock" => halftime ? "0.0" : "6:30",
            "startTime" => Time.now().value() + 3600,
            "detail" => halftime ? "Halftime" : "",
            "away" => {"abbr" => "MCK", "name" => "Mockers", "record" => "4-6", "score" => t * 3 + 2},
            "home" => {"abbr" => "DAL", "name" => "Mavericks", "record" => "7-3", "score" => t * 4}
        };
    }

    // ---------- Parsing (Worker returns a flat dictionary) ----------

    // Returns true if polling should continue (game not final).
    private function parseGame(d as Dictionary) as Boolean {
        var state = (d["state"] != null) ? d["state"].toString() : "";
        var period = null;
        if (d["period"] instanceof Number) {
            period = d["period"];
        }
        var clock = (d["clock"] != null) ? d["clock"].toString() : "";
        var detail = (d["detail"] != null) ? d["detail"].toString() : "";
        var statusName = (d["statusName"] != null) ? d["statusName"].toString() : "";
        var halftime = statusName.equals("STATUS_HALFTIME") || detail.equals("Halftime");

        // Away team on the left, home team on the right
        var away = d["away"];
        var home = d["home"];
        _hasGame = false;
        if (away instanceof Dictionary && home instanceof Dictionary) {
            _hasGame = true;
            var live = !state.equals("pre");
            _awayAbbr = teamAbbr(away);
            _homeAbbr = teamAbbr(home);
            _awayRec = teamRecord(away);
            _homeRec = teamRecord(home);
            _awayScore = (live && away["score"] instanceof Number) ? away["score"].toString() : "";
            _homeScore = (live && home["score"] instanceof Number) ? home["score"].toString() : "";
        }

        // Status
        var start = d["startTime"];
        if (halftime) {
            _status = "Halftime";
        } else if (state.equals("in") && period != null) {
            _status = periodLabel(period) + " " + clock;
        } else if (state.equals("post")) {
            _status = "Final";
        } else if (start instanceof Number) {
            _status = "Starts " + formatTime(start);
        } else if (detail.length() > 0) {
            _status = detail;
        } else {
            _status = "Scheduled";
        }

        detectQuarterChange(state, period);
        return !state.equals("post");
    }

    private function teamRecord(t as Dictionary) as String {
        return (t["record"] != null) ? t["record"].toString() : "";
    }

    private function teamAbbr(t as Dictionary) as String {
        return (t["abbr"] != null) ? t["abbr"].toString() : "???";
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
        var leftX = w * 28 / 100;     // away team column
        var rightX = w * 72 / 100;    // home team column

        if (_hasGame) {
            // Row 1: quarter + time remaining (or start time / Final)
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 17 / 100, Graphics.FONT_SMALL, _status, just);

            // Row 2: team abbreviations (larger), away left / home right
            dc.drawText(leftX, h * 35 / 100, Graphics.FONT_LARGE, _awayAbbr, just);
            dc.drawText(rightX, h * 35 / 100, Graphics.FONT_LARGE, _homeAbbr, just);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 35 / 100, Graphics.FONT_XTINY, "vs", just);

            // Row 3: win/loss record, aligned under each team
            dc.drawText(leftX, h * 50 / 100, Graphics.FONT_XTINY, _awayRec, just);
            dc.drawText(rightX, h * 50 / 100, Graphics.FONT_XTINY, _homeRec, just);

            // Row 4: score (largest), aligned under each team
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(leftX, h * 68 / 100, Graphics.FONT_NUMBER_MEDIUM, _awayScore, just);
            dc.drawText(rightX, h * 68 / 100, Graphics.FONT_NUMBER_MEDIUM, _homeScore, just);
        }

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        if (_msg.length() > 0) {
            dc.drawText(w / 2, h * (_hasGame ? 88 : 50) / 100, Graphics.FONT_SMALL, _msg, just);
        } else if (_updated.length() > 0) {
            dc.drawText(w / 2, h * 88 / 100, Graphics.FONT_XTINY, "Upd " + _updated, just);
        }
    }
}
