@echo off
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe

if not exist "%CSC%" (
    echo Error: C# Compiler (csc.exe) not found at %CSC%
    pause
    exit /b 1
)

echo Building NativeEngine.exe from C# source...
"%CSC%" /nologo /target:exe /main:NativeEngine.Program /platform:anycpu /out:"..\..\bin\NativeEngine.exe" NativeDisplay.cs NativeHardwareSuite.cs

if %ERRORLEVEL% EQU 0 (
    echo Build successful: bin\NativeEngine.exe
) else (
    echo Build failed with error code %ERRORLEVEL%
)
