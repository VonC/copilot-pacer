@echo off

REM ******************************************************************
REM Script Name:  senv.bat
REM Description:  environment setup for copilot-pacer
REM
REM Parameters:
REM none
REM
REM Usage:
REM First script to be called to setup the environment for the project
REM
REM Return Value: 0 - Success, 1 - Error
REM
REM ******************************************************************

for %%i in ("%~dp0") do SET "PRJ_DIR=%%~fi"
set "PRJ_DIR=%PRJ_DIR:~0,-1%"
for %%i in ("%PRJ_DIR%") do SET "PRJ_DIR_NAME=%%~nxi"

if defined NO_MORE_SENV_%PRJ_DIR_NAME% ( goto:eof )

call %~dp0tools\init.bat $*

%_ok% "Environment initialized for project '%PRJ_DIR_NAME%'"

REM ========================================
REM NODE.JS SETUP — Node 22 from %PRGS%\nodes\node22
REM ========================================
if not exist "%PRGS%\nodes\node22" (
  %_fatal% "Directory '%PRGS%\nodes\node22' not found." 110
  goto:eof
)

REM Add Node 22 to PATH (only once)
echo ;%PATH%; | findstr /C:";%PRGS%\nodes\node22;" >NUL 2>&1
if errorlevel 1 (
  set "PATH=%PRGS%\nodes\node22;%PATH%"
)

REM Verify node is accessible
where node >NUL 2>&1
if errorlevel 1 (
  %_fatal% "node.exe not found in '%PRGS%\nodes\node22'." 111
  goto:eof
)

for /f "tokens=*" %%v in ('node --version') do set "NODE_VERSION=%%v"
%_info% "Using Node.js %NODE_VERSION% from '%PRGS%\nodes\node22'"

REM ========================================
REM PROJECT SHORTCUTS
REM ========================================
doskey a="%PRJ_DIR%\all.bat" $* ^& echo copilot-pacer: all done
doskey b="%PRJ_DIR%\build.bat" $* ^& echo copilot-pacer: build done
doskey t="%PRJ_DIR%\test.bat" $* ^& echo copilot-pacer: test done

doskey cdp=cd "%PRJ_DIR%" ^& echo copilot-pacer: changed directory to project root done
doskey ni=cd "%PRJ_DIR%" ^&^& npm install ^& echo copilot-pacer: npm install done
doskey nb=cd "%PRJ_DIR%" ^&^& npm run compile ^& echo copilot-pacer: npm compile done
doskey nw=cd "%PRJ_DIR%" ^&^& npm run watch ^& echo copilot-pacer: npm watch done
doskey nl=cd "%PRJ_DIR%" ^&^& npm run lint ^& echo copilot-pacer: npm lint done
doskey nt=cd "%PRJ_DIR%" ^&^& npm run pretest ^& echo copilot-pacer: npm test done
doskey np=cd "%PRJ_DIR%" ^&^& vsce package ^& echo copilot-pacer: vsce package done

REM ========================================
REM Add project root to PATH (for scripts)
REM ========================================
echo ;%PATH%; | findstr /C:";%PRJ_DIR%;" >NUL 2>&1
if errorlevel 1 (
  set "PATH=%PRJ_DIR%;%PATH%"
)

REM ========================================
REM Add copilot-shared\bin to PATH (for scripts)
REM ========================================
for %%i in ("%PRJ_DIR%\..\copilot-shared\bin") do set "SHARED_BIN=%%~fi"
echo ;%PATH%; | findstr /C:";%SHARED_BIN%;" >NUL 2>&1
if errorlevel 1 (
  set "PATH=%SHARED_BIN%;%PATH%"
)

REM Set project-specific flag when done
REM Next call to senv.bat will be skipped
set "NO_MORE_SENV_%PRJ_DIR_NAME%=true"

%_info% "senv applied for '%PRJ_DIR_NAME%'"

goto:eof

:call_echos_stack
if not defined ECHOS_STACK ( set "CURRENT_SCRIPT=%~nx0" & goto:eof ) else ( call "%PRJ_DIR%\tools\batcolors\echos.bat" :stack %~nx0 )
goto:eof
