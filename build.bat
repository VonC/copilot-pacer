@echo off


::  ===============================================
::  INITIAL SETUP
::  ===============================================
for %%i in ("%~dp0") do SET "build_dir=%%~fi"
set "build_dir=%build_dir:~0,-1%"

call <NUL "%build_dir%\senv.bat"
call "%build_dir%\tools\dev_workflow\t_build.bat" :pre-processing %*

::  ===============================================
::  BUILD PROJECT
::  ===============================================
%_stack_call% "%build_dir%\tools\dev_workflow\get-version.bat"

rem Pre-build steps here, if needed.

%_info% "----------------------------------------"
%_info% "Build the project '%PRJ_DIR_NAME%', version '%project_version%'"
%_info% "----------------------------------------"

REM build_params_echos is set by tools\dev_workflow\t_build.bat :pre-processing
REM it replaces " by ' for preserving double quotes in params
%_task% "Start build of '%PRJ_DIR_NAME%' with build_params '%build_params_echos%'"

REM --- Step 1: npm install (ensure dependencies are present) ---
%_info% "Installing npm dependencies..."
pushd "%PRJ_DIR%"
call npm install
if errorlevel 1 (
  %_fatal% "npm install failed." 10
  popd
  set "build_status=1"
  goto :post
)
popd

REM --- Step 2: TypeScript compilation ---
%_info% "Compiling TypeScript..."
pushd "%PRJ_DIR%"
call npm run compile
set "build_status=%ERRORLEVEL%"
popd

if not "%build_status%"=="0" (
  %_fatal% "TypeScript compilation failed." 11
  goto :post
)

REM --- Step 3: Lint ---
%_info% "Running ESLint..."
pushd "%PRJ_DIR%"
call npm run lint
set "build_status=%ERRORLEVEL%"
popd

if not "%build_status%"=="0" (
  %_warn% "Lint reported issues (exit code %build_status%)."
  REM Non-fatal: continue with warnings
  set "build_status=0"
)

%_ok% "Build of '%PRJ_DIR_NAME%' completed successfully."

:post
REM check if this build is a release build for which a "valid" marker needs to be created
call "%build_dir%\tools\dev_workflow\t_build.bat" :post-processing %build_status%
call:build_unset
exit /b %build_status%
goto:eof

::##################################################
::  CLEANUP
::##################################################

:build_unset
call "%build_dir%\senv.bat" unset
call "%build_dir%\tools\dev_workflow\t_build.bat" :build_unset
set "build_dir="
goto:eof

::##################################################
::  ECHOS STACK (called by echos.bat)
::##################################################

:call_echos_stack
if not defined ECHOS_STACK ( set "CURRENT_SCRIPT=%~nx0" & goto:eof ) else ( call "%PRJ_DIR%\tools\batcolors\echos.bat" :stack %~nx0 )
goto:eof
