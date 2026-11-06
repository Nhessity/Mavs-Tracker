import Toybox.Lang;
import Toybox.WatchUi;

class MavsTrackerDelegate extends WatchUi.BehaviorDelegate {

    private var _view as MavsTrackerView;

    function initialize(view as MavsTrackerView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    // SELECT / START button: manual vibration test
    function onSelect() as Boolean {
        _view.testVibrate();
        return true;
    }

    // UP / DOWN: manual refresh (useful after polling has stopped)
    function onNextPage() as Boolean {
        _view.refresh();
        return true;
    }

    function onPreviousPage() as Boolean {
        _view.refresh();
        return true;
    }
}
