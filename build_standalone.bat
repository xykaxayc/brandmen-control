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

echo ========================================
echo   DONE! Your portable app is in "dist" folder.
echo   You can copy the "dist" folder to any PC.
echo   Run "brandmen_windows.exe" to start.
echo ========================================
pause
