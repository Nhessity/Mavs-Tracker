import Toybox.Lang;
import Toybox.WatchUi;

class Mavs_TrackerDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onMenu() as Boolean {
        WatchUi.pushView(new Rez.Menus.MainMenu(), new Mavs_TrackerMenuDelegate(), WatchUi.SLIDE_UP);
        return true;
    }

}