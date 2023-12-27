msdf-atlas-gen.exe  -font %1 -charset ascii_charset.txt -type msdf -json %~n1.json -imageout %~n1.png
7z.exe a -sdel -- %~n1.tar %~n1.json %~n1.png