from pathlib import Path

app = Path(defines["app"])
files = [str(app)]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
background = defines["background"]
window_rect = ((160, 140), (640, 350))
icon_size = 104
text_size = 13
icon_locations = {app.name: (170, 183), "Applications": (470, 183)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
