@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem flutter_vodozemac 0.5.0 assumes FLUTTER_ROOT is inherited by Gradle.
rem Direct .\gradlew.bat invocations do not provide it, so resolve the exact
rem Flutter SDK chosen for this Android project before calling Cargokit.
if not defined CARGOKIT_ROOT_PROJECT_DIR (
    echo ERROR: CARGOKIT_ROOT_PROJECT_DIR is not set.
    exit /b 1
)

set "LOCAL_PROPERTIES=%CARGOKIT_ROOT_PROJECT_DIR%\local.properties"
if not exist "%LOCAL_PROPERTIES%" (
    echo ERROR: Android local.properties is missing: "%LOCAL_PROPERTIES%"
    exit /b 1
)

set "FLUTTER_ROOT="
for /f "usebackq tokens=1,* delims==" %%A in ("%LOCAL_PROPERTIES%") do (
    if /I "%%A"=="flutter.sdk" set "FLUTTER_ROOT=%%B"
)

if not defined FLUTTER_ROOT (
    echo ERROR: flutter.sdk is not set in "%LOCAL_PROPERTIES%".
    exit /b 1
)
if not exist "%FLUTTER_ROOT%\bin\cache\dart-sdk\bin\dart.exe" (
    echo ERROR: Flutter SDK from local.properties is invalid: "%FLUTTER_ROOT%"
    exit /b 1
)
if not defined CARGOKIT_MANIFEST_DIR (
    echo ERROR: CARGOKIT_MANIFEST_DIR is not set.
    exit /b 1
)
if not defined CARGOKIT_OUTPUT_DIR (
    echo ERROR: CARGOKIT_OUTPUT_DIR is not set.
    exit /b 1
)
if not defined CARGOKIT_TARGET_PLATFORMS (
    echo ERROR: CARGOKIT_TARGET_PLATFORMS is not set.
    exit /b 1
)

for %%I in ("%CARGOKIT_MANIFEST_DIR%\..") do set "CARGOKIT_PACKAGE_ROOT=%%~fI"
set "CARGOKIT_RUNNER=%CARGOKIT_PACKAGE_ROOT%\cargokit\run_build_tool.cmd"
if not exist "%CARGOKIT_RUNNER%" (
    echo ERROR: flutter_vodozemac Cargokit runner is missing: "%CARGOKIT_RUNNER%"
    exit /b 1
)

rem Do not let an old artifact turn an upstream false-success into a pass.
for %%T in (%CARGOKIT_TARGET_PLATFORMS:,= %) do (
    call :abi_for_target "%%T" ABI
    if defined ABI del /q "%CARGOKIT_OUTPUT_DIR%\%ABI%\libvodozemac_bindings_dart.so" >nul 2>&1
)

echo [OREX] Building flutter_vodozemac with Flutter SDK from local.properties.
call "%CARGOKIT_RUNNER%" %*
set "RUNNER_EXIT=%ERRORLEVEL%"
if not "%RUNNER_EXIT%"=="0" exit /b %RUNNER_EXIT%

set "MISSING_LIBRARY="
for %%T in (%CARGOKIT_TARGET_PLATFORMS:,= %) do (
    call :abi_for_target "%%T" ABI
    if defined ABI if not exist "%CARGOKIT_OUTPUT_DIR%\%ABI%\libvodozemac_bindings_dart.so" (
        echo ERROR: Cargokit did not produce libvodozemac_bindings_dart.so for %%T.
        set "MISSING_LIBRARY=1"
    )
)

if defined MISSING_LIBRARY exit /b 1
exit /b 0

:abi_for_target
set "%~2="
if /I "%~1"=="android-arm" set "%~2=armeabi-v7a"
if /I "%~1"=="android-arm64" set "%~2=arm64-v8a"
if /I "%~1"=="android-x86" set "%~2=x86"
if /I "%~1"=="android-x64" set "%~2=x86_64"
exit /b 0
