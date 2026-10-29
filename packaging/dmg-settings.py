"""Finder layout for the drag-to-Applications disk image; evaluated by dmgbuild."""
import os

application = defines["app"]
files = [application]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
background = defines["background"]
icon = os.path.join(application, "Contents/Resources/AppIcon.icns")
window_rect = ((160, 160), (660, 400))
icon_locations = {"Trimsmith.app": (170, 205), "Applications": (490, 205)}
icon_size = 112
text_size = 14
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
