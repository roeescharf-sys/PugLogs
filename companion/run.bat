@echo off
rem Starts the PugLogs companion on Windows. The first run sets up its Python environment.
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
	echo First run: installing dependencies...
	where py >nul 2>nul && (py -3 -m venv .venv) || (python -m venv .venv)
	if not exist ".venv\Scripts\python.exe" (
		echo Python 3 was not found. Install it from https://www.python.org/downloads/ and run this again.
		pause
		exit /b 1
	)
	".venv\Scripts\python.exe" -m pip install --quiet -r requirements.txt
)
".venv\Scripts\python.exe" app.py %*
if errorlevel 1 pause
