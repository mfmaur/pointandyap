# Writes the installer window's .DS_Store into a mounted, writable disk image: icon view, no bars, 720 x 426 pt of
# content, the app left and Applications right, the background at .background/background.tiff. Only a classic alias
# points at the background (no bookmark): a bookmark carries the build volume's id, which no longer matches once the
# image is compressed, and Finder then draws no background.
# Usage: python layout.py <mount point> <app name>
import os
import sys
from ds_store import DSStore
from mac_alias import Alias

mount, app = sys.argv[1], sys.argv[2]
alias = Alias.for_file(os.path.join(mount, ".background", "background.tiff")).to_bytes()
with DSStore.open(os.path.join(mount, ".DS_Store"), "w+") as d:
    d["."]["bwsp"] = {
        "ContainerShowSidebar": False, "PreviewPaneVisibility": False, "ShowPathbar": False, "ShowSidebar": False,
        "ShowStatusBar": False, "ShowTabView": False, "ShowToolbar": False, "SidebarWidth": 0,
        "WindowBounds": "{{240, 180}, {720, 458}}",
    }
    d["."]["icvp"] = {
        "arrangeBy": "none", "backgroundType": 2, "backgroundImageAlias": alias,
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0, "iconSize": 112.0, "labelOnBottom": True,
        "scrollPositionX": 0.0, "scrollPositionY": 0.0, "showIconPreview": False, "showItemInfo": False,
        "textSize": 13.0, "viewOptionsVersion": 1,
    }
    d["."]["vSrn"] = ("long", 1)
    d["."]["vstl"] = ("type", b"icnv")
    d[app]["Iloc"] = (180, 200)
    d["Applications"]["Iloc"] = (540, 200)
print("layout written")
