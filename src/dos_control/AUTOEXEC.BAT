@echo off
set blaster=a220 i5 d1 h5 t6
path b:\;a:\;c:\
cls
if exist b:\readme.txt (
    type b:\readme.txt
) else if exist readme.txt (
    type readme.txt
)
b:
