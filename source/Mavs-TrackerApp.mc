import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class MavsTrackerApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        var view = new MavsTrackerView();
        return [view, new MavsTrackerDelegate(view)];
    }
}
