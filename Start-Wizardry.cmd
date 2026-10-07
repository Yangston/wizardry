@echo off
setlocal
cd /d "%~dp0"
echo Starting Wizardry receiver and computer studio.
echo Default mode records sensors and simulates commands. Use --execute for computer controls.
python receiver\server.py --host 0.0.0.0 --token-file receiver\.pairing-token %*
if errorlevel 1 (
  echo Receiver stopped with an error. Check Python 3.10+ and whether another receiver is using port 8765.
  pause
)
