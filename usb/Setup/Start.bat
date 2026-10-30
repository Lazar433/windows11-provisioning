@echo off
rem ==========================================================================
rem  Start.bat - pokrece Setup.ps1
rem  - ExecutionPolicy Bypass vazi samo za ovaj jedan PowerShell proces
rem  - argumenti se prosledjuju dalje:  Start.bat -DryRun -Section Region,Apps
rem  - ako nije pokrenut kao administrator, Setup.ps1 sam trazi admin prava (UAC)
rem  - pause na kraju drzi prozor sa rezultatom (FirstLogonCommands ga pokrecu preko "start", ne blokira logovanje)
rem ==========================================================================

rem -Command (a ne -File) da bi -Section Region,Apps stigao kao niz, ne kao jedan string.
rem $LASTEXITCODE = 2 unapred: ako Setup.ps1 uopste ne krene (npr. pogresno ime sekcije), izlaz je 2.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$LASTEXITCODE = 2; & '%~dp0Setup.ps1' %*; exit $LASTEXITCODE"
set "SETUP_EXIT=%ERRORLEVEL%"

echo.
echo Setup.ps1 je zavrsio. Exit code: %SETUP_EXIT%  (0 = OK, 1 = bilo je gresaka, 2 = nije pokrenut)
echo Logovi: na flesu u Logs\ (u korenu flesa, folder po racunaru). Izvestaj: desktop.
echo Na racunaru se %ProgramData%\Provisioning brise tek kad je kopija na fles proverena (SHA256);
echo ako je bilo gresaka ili kopija nije uspela, logovi ostaju tamo (precica "Provisioning LOGOVI" na desktopu).
pause
exit /b %SETUP_EXIT%
