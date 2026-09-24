# README screenshot: the ARGO-7 demo held at T+02:14.
#
#   zig build example -Doptimize=ReleaseSafe
#   vhs assets/demo-screenshot.tape
#
# `--at` freezes the flight, so every run produces the same frame.

Output .zig-cache/demo-screenshot.gif

Set Shell bash
Set FontSize 16
Set Width 1080
Set Height 680
Set Padding 20
Set Theme { "name": "tuiz", "background": "#0a1215", "foreground": "#e6edf3", "cursor": "#0a1215", "selection": "#1f4a52", "black": "#0a1215", "red": "#ef4444", "green": "#2dd4bf", "yellow": "#f5c518", "blue": "#5f7f86", "magenta": "#9fb8bd", "cyan": "#2dd4bf", "white": "#e6edf3", "brightBlack": "#5f7f86", "brightRed": "#ef4444", "brightGreen": "#2dd4bf", "brightYellow": "#f5c518", "brightBlue": "#9fb8bd", "brightMagenta": "#9fb8bd", "brightCyan": "#2dd4bf", "brightWhite": "#ffffff" }

Hide
Type "./zig-out/bin/tuiz-demo --at 134"
Enter
Sleep 1s
Show
Screenshot assets/demo.png
Sleep 100ms
