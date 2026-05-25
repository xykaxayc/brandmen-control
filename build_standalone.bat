@echo off
echo ========================================
echo   Brandmen Pro: STANDALONE BUILDER
echo ========================================

echo [1/4] Cleaning old builds...
if exist "dist" rd /s /q "dist"
if exist "build\windows" rd /s /q "build\windows"

echo [2/4] Fetching dependencies...
call flutter pub get

echo [3/4] Building Windows Release...
call flutter build windows --release

if %ERRORLEVEL% NEQ 0 (
    echo X Error during build!
    pause
    exit /b %ERRORLEVEL%
)

echo [4/4] Creating Standalone Bundle...
mkdir dist
xcopy /s /e "build\windows\x64\runner\Release\*" "dist\"

echo [5/4] Downloading ADB platform-tools for Windows...
powershell -Command "Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile 'platform-tools.zip' -UseBasicParsing"
if %ERRORLEVEL% NEQ 0 (
    echo ! ADB download failed. Add ADB manually to dist\platform-tools\
    goto :done
)
powershell -Command "Expand-Archive -Path 'platform-tools.zip' -DestinationPath 'dist' -Force"
del platform-tools.zip

:done
echo ========================================
echo   DONE! Portable app is in "dist" folder.
echo   ADB bundled in dist\platform-tools\adb.exe
echo   Run "brandmen_windows.exe" to start.
echo ========================================
pause
