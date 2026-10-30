@echo off
rem ==========================================================================
rem  Check-Disk.cmd - provera PRE brisanja diska (Windows Setup, WinPE)
rem  Poziva ga autounattend.xml (windowsPE, RunSynchronous) pre nego sto Setup obrise Disk 0.
rem  Brisanje je dozvoljeno SAMO ako:
rem    1. Disk 0 je unutrasnji disk (nije USB, nije nepoznat tip) i nema diska nepoznatog tipa,
rem    2. postoji tacno JEDAN unutrasnji disk - ILI ih ima vise (npr. NVMe + HDD) i tehnicar, posle prikaza
rem       svih diskova, upise DA (2026-10-26). I tada se brise SAMO Disk 0, ostali diskovi se ne diraju.
rem    3. na racunaru nije vec instalacija sa ovog flesa (petlja: posle restarta racunar ponovo
rem       butuje sa flesa, a Setup bi obrisao upravo instaliran Windows).
rem  Ako nesto ne valja: zapis u <fles>\Logs\Disk_check.txt i GASENJE racunara (nista nije obrisano).
rem  Logs\ je u KORENU flesa (isti folder kao logovi Setup.ps1; Setup.ps1 kopira Disk_check.txt u folder racunara).
rem  Ako je sve OK: X:\Windows\Temp\disk-ok.txt - bez tog fajla autounattend.xml gasi racunar.
rem  Argument %1 = slovo flesa (npr. D:), za log.
rem
rem  KOMANDE (boot.wim sa MCT flesa NEMA findstr, timeout, choice - test B, pokusaj 1):
rem  SAMO ugradjene cmd komande + find.exe, diskpart.exe, wpeutil.exe.
rem  PRAVILO: sve sto ne uspe ili vrati prazan rezultat = STOP, nista se ne brise.
rem ==========================================================================
setlocal EnableDelayedExpansion
set "FLASH=%~1"
set "LOGDIR=%FLASH%\Logs"
set "LOG=%LOGDIR%\Disk_check.txt"
set "TMPD=X:\Windows\Temp"
set "REASON=Nepoznat razlog."
set "HINT="
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
del /q "%TMPD%\disk-ok.txt" 2>nul
if exist "%TMPD%\disk-ok.txt" (
    set "REASON=Stara potvrda %TMPD%\disk-ok.txt ne moze da se obrise."
    goto STOP
)

>> "%LOG%" echo ===== %date% %time% - Check-Disk.cmd, fles %FLASH%

rem --- 1 i 2: tip svakog diska (Disk 0-7) iz "diskpart detail disk", red "Type : NVMe / SATA / USB ..."
set INTERNAL=0
set "DISK0=NEMA"
set "UNKNOWN="
set "CHECKERR="
for /L %%i in (0,1,7) do call :CHECKDISK %%i
>> "%LOG%" echo Disk 0: %DISK0% / unutrasnjih diskova: %INTERNAL% / nepoznatog tipa:%UNKNOWN%

rem --- 3: vec instalirano sa ovog flesa? Windows Setup kesira odgovore u \Windows\Panther\unattend.xml;
rem     Setup.ps1 ga brise pri prvom pokretanju - postoji samo dok instalacija nije zavrsena.
set "LOOP="
for %%d in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do call :CHECKLOOP %%d

rem --- Odluka: prvo greske u samoj proveri, pa ostali razlozi. Brisanje SAMO ako je sve proslo.
if defined CHECKERR (
    set "REASON=Provera nije pouzdana: !CHECKERR!"
    goto STOP
)
if defined LOOP goto STOP_LOOP
if not "%DISK0%"=="INTERNAL" goto STOP_DISK0
if defined UNKNOWN goto STOP_UNKNOWN
rem Disk 0 je unutrasnji, pa INTERNAL nije 0: razlicito od 1 = vise unutrasnjih diskova -> pitanje
if not "%INTERNAL%"=="1" goto CONFIRM
set "OKMSG=OK: Disk 0 je jedini unutrasnji disk - Setup ga brise i instalira Windows."

:WRITE_OK
> "%TMPD%\disk-ok.txt" echo OK
if not exist "%TMPD%\disk-ok.txt" (
    set "REASON=Potvrda %TMPD%\disk-ok.txt nije napisana."
    goto STOP
)
>> "%LOG%" echo !OKMSG!
exit /b 0

rem ==========================================================================
rem  :CONFIRM - vise unutrasnjih diskova: prikaz SVIH diskova (tip, model, velicina, particije, volumeni),
rem  pa pitanje preko "set /p" (ugradjeno u cmd). Samo tacno "DA" ili "da" = brisanje Disk 0.
rem  Sve ostalo (drugi tekst, prazan unos, greska set /p) = STOP. Bez timeout-a - ceka tehnicara.
rem  Sve sto je prikazano ide i u log (:SAY), zajedno sa odgovorom.
rem ==========================================================================
:CONFIRM
rem Velicina diska postoji samo u "list disk" (jedan poziv za sve diskove)
> "%TMPD%\dp.txt" echo list disk
diskpart /s "%TMPD%\dp.txt" > "%TMPD%\dp_list.txt" 2>&1
>> "%LOG%" echo --- list disk
type "%TMPD%\dp_list.txt" >> "%LOG%"
for /L %%i in (0,1,7) do call :DISKINFO %%i
>> "%LOG%" echo --- Prikazano tehnicaru:
set "MSG="
call :SAY
set "MSG=PAZNJA: na racunaru ima vise unutrasnjih diskova (%INTERNAL%):"
call :SAY
for /L %%i in (0,1,7) do call :SHOWDISK %%i
set "MSG="
call :SAY
set "MSG=Windows ce se instalirati na DISK 0 i on ce biti OBRISAN. Ostali diskovi se NE diraju."
call :SAY
set "MSG="
call :SAY
set "ANSWER="
set /p "ANSWER=Upisi DA za nastavak, bilo sta drugo = stop: "
rem !ANSWER! (odlozena ekspanzija): znaci kao & > " u odgovoru se samo ispisu, ne izvrsavaju
>> "%LOG%" echo Pitanje "Upisi DA za nastavak, bilo sta drugo = stop" - odgovor tehnicara: [!ANSWER!] u %time%
if "!ANSWER!"=="DA" goto CONFIRM_OK
if "!ANSWER!"=="da" goto CONFIRM_OK
set "REASON=Unutrasnjih diskova: %INTERNAL% - tehnicar nije upisao DA, Disk 0 se ne brise."
set "HINT=Za instalaciju na drugi disk: preimenuj autounattend.xml u autounattend.xml.off, instaliraj rucno, pa pokreni Setup\Start.bat kao administrator. Posle VRATI ime."
goto STOP

:CONFIRM_OK
set "OKMSG=OK: tehnicar upisao DA - Setup brise Disk 0 i instalira Windows, ostali diskovi se ne diraju."
goto WRITE_OK

rem ==========================================================================
rem  :SAY - ispis promenljive MSG na ekran i u log (echo( ispisuje i prazan red)
rem ==========================================================================
:SAY
echo(!MSG!
>> "%LOG%" echo(!MSG!
exit /b 0

rem ==========================================================================
rem  :CHECKDISK <broj> - diskpart "detail disk", tip diska iz reda "Type : ...".
rem  Unutrasnji = SAMO poznati tipovi (NVMe SATA SAS ATA RAID SCSI); USB = USB; ostalo = NEPOZNAT (STOP).
rem  Nema reda "Type" = disk ne postoji (ili diskpart nije radio) - za Disk 0 to znaci NEMA = STOP.
rem ==========================================================================
:CHECKDISK
set "DP=%TMPD%\dp_%1.txt"
> "%TMPD%\dp.txt" echo select disk %1
>> "%TMPD%\dp.txt" echo detail disk
diskpart /s "%TMPD%\dp.txt" > "%DP%" 2>&1
set "BUS="
rem for /f deli svaki red na ":" - levo kljuc (bez razmaka), desno vrednost
for /f "usebackq tokens=1,* delims=:" %%a in ("%DP%") do (
    set "KEY=%%a"
    set "KEY=!KEY: =!"
    if /i "!KEY!"=="Type" if not defined BUS set "BUS=%%b"
)
if not defined BUS (
    if "%1"=="0" (
        >> "%LOG%" echo --- Disk 0: nema reda Type u izlazu diskpart-a
        type "%DP%" >> "%LOG%"
    )
    exit /b 0
)
set "BUS=!BUS: =!"
set "KIND=NEPOZNAT"
for %%t in (NVMe SATA SAS ATA RAID SCSI) do if /i "!BUS!"=="%%t" set "KIND=INTERNAL"
if /i "!BUS!"=="USB" set "KIND=USB"
rem find: 0 = nadjeno, 1 = nije nadjeno, ostalo (npr. 9009 = find.exe ne postoji) = greska provere
find /i "No Media" "%DP%" >nul 2>&1
set "RC=!errorlevel!"
if "!RC!"=="0" set "KIND=PRAZAN"
if not "!RC!"=="0" if not "!RC!"=="1" set "CHECKERR=find.exe nije radio na disku %1 (errorlevel !RC!)"
>> "%LOG%" echo --- Disk %1: !KIND! (Type: !BUS!)
type "%DP%" >> "%LOG%"
if "!KIND!"=="INTERNAL" set /a INTERNAL+=1
if "!KIND!"=="NEPOZNAT" set "UNKNOWN=!UNKNOWN! %1-!BUS!"
if "%1"=="0" set "DISK0=!KIND!"
rem Za prikaz kod vise diskova (:CONFIRM): disk postoji, tip i Type iz diskpart-a
set "D%1_KIND=!KIND!"
set "D%1_BUS=!BUS!"
exit /b 0

rem ==========================================================================
rem  :DISKINFO <broj> - SAMO za prikaz (ne odlucuje nista): model, velicina, broj particija, volumeni.
rem  Model i volumeni iz vec snimljenog "detail disk" (dp_N.txt), velicina iz "list disk" (dp_list.txt),
rem  particije iz posebnog "list partition" - provera tipa iznad ostaje ista kao pre.
rem ==========================================================================
:DISKINFO
if not defined D%1_KIND exit /b 0
set "MODEL="
set "NEXTMODEL="
set "VOLHDR="
set "VOLS="
set "SIZE="
set PARTS=0
for /f "usebackq delims=" %%L in ("%TMPD%\dp_%1.txt") do (
    set "LINE=%%L"
    call :INFOLINE
)
rem "  Disk 0    Online   238 GB   0 B   *" - status moze biti i dve reci ("No Media"),
rem pa je velicina 4.+5. rec ako je 5. rec jedinica, inace 5.+6.
for /f "usebackq tokens=1-6" %%a in ("%TMPD%\dp_list.txt") do if "%%a"=="Disk" if "%%b"=="%1" (
    set "SIZE=%%e %%f"
    for %%u in (B KB MB GB TB PB) do if "%%e"=="%%u" set "SIZE=%%d %%e"
)
> "%TMPD%\dp.txt" echo select disk %1
>> "%TMPD%\dp.txt" echo list partition
diskpart /s "%TMPD%\dp.txt" > "%TMPD%\dpp_%1.txt" 2>&1
>> "%LOG%" echo --- Disk %1: list partition
type "%TMPD%\dpp_%1.txt" >> "%LOG%"
rem Redovi "  Partition 1    System   260 MB ..." - zaglavlje "Partition ###" se ne broji
for /f "usebackq tokens=1,2" %%a in ("%TMPD%\dpp_%1.txt") do if "%%a"=="Partition" if not "%%b"=="###" set /a PARTS+=1
set "D%1_MODEL=!MODEL!"
set "D%1_SIZE=!SIZE!"
set "D%1_PARTS=!PARTS!"
set "D%1_VOLS=!VOLS!"
exit /b 0

rem ==========================================================================
rem  :INFOLINE - jedan red "detail disk" iz LINE:
rem  - model = prvi red posle "Disk N is now the selected disk." (prazne redove for /f preskace);
rem  - volumeni = redovi "  Volume N" ispod zaglavlja tabele. Kolone su na stalnim mestima
rem    (Ltr od 14, Label od 19, Fs od 32, Size od 51) - proverava se na zaglavlju; ako se ne poklapa,
rem    red volumena ide u prikaz ceo (RAW), bez deljenja na kolone.
rem ==========================================================================
:INFOLINE
if defined NEXTMODEL (
    set "NEXTMODEL="
    if /i not "!LINE:~0,8!"=="Disk ID:" (
        set "MODEL=!LINE!"
        call :TRIM MODEL
    )
    exit /b 0
)
if not "!LINE:is now the selected disk=!"=="!LINE!" (
    set "NEXTMODEL=1"
    exit /b 0
)
if "!LINE:~2,10!"=="Volume ###" (
    set "VOLHDR=RAW"
    if "!LINE:~14,3!"=="Ltr" if "!LINE:~19,5!"=="Label" if "!LINE:~32,2!"=="Fs" if "!LINE:~51,4!"=="Size" set "VOLHDR=COL"
    exit /b 0
)
if not defined VOLHDR exit /b 0
if not "!LINE:~2,7!"=="Volume " exit /b 0
if "!VOLHDR!"=="RAW" (
    set "V=!LINE!"
    call :TRIM V
    goto INFOLINE_ADD
)
set "V_LTR=!LINE:~14,3!"
if defined V_LTR set "V_LTR=!V_LTR: =!"
set "V_LBL=!LINE:~19,11!"
call :TRIM V_LBL
set "V_FS=!LINE:~32,5!"
if defined V_FS set "V_FS=!V_FS: =!"
set "V_SIZE=!LINE:~51,7!"
call :TRIM V_SIZE
rem Oblik: C: 'Windows' NTFS 237 GB (bez slova / oznake - samo ono sto postoji)
set "V="
if defined V_LTR set "V=!V_LTR!: "
if defined V_LBL set "V=!V!'!V_LBL!' "
if defined V_FS set "V=!V!!V_FS! "
set "V=!V!!V_SIZE!"
:INFOLINE_ADD
if not defined V exit /b 0
if defined VOLS (set "VOLS=!VOLS!, !V!") else set "VOLS=!V!"
exit /b 0

rem ==========================================================================
rem  :SHOWDISK <broj> - jedan red za tehnicara, npr.
rem  "Disk 0: NVMe ADATA SX8200NP 238 GB, particija: 3 | C: 'Windows' NTFS 237 GB, FAT32 260 MB"
rem ==========================================================================
:SHOWDISK
if not defined D%1_KIND exit /b 0
set "MSG=Disk %1: !D%1_BUS!"
if "!D%1_KIND!"=="PRAZAN" set "MSG=!MSG! (nema medija)"
if "!D%1_KIND!"=="USB" set "MSG=!MSG! (fles ili spoljni disk)"
if defined D%1_MODEL set "MSG=!MSG! !D%1_MODEL!"
if defined D%1_SIZE (set "MSG=!MSG! !D%1_SIZE!") else set "MSG=!MSG! (velicina ?)"
set "MSG=!MSG!, particija: !D%1_PARTS! | "
if defined D%1_VOLS (set "MSG=!MSG!!D%1_VOLS!") else set "MSG=!MSG!(prazan)"
call :SAY
exit /b 0

rem ==========================================================================
rem  :TRIM <ime promenljive> - brise razmake na pocetku i na kraju vrednosti
rem ==========================================================================
:TRIM
if not defined %1 exit /b 0
for /f "tokens=* delims= " %%t in ("!%1!") do set "%1=%%t"
:TRIM_END
if not defined %1 exit /b 0
if "!%1:~-1!"==" " (
    set "%1=!%1:~0,-1!"
    goto TRIM_END
)
exit /b 0

rem ==========================================================================
rem  :CHECKLOOP <slovo> - kes odgovora na tom slovu sadrzi nasu oznaku ili ime pc1 = ponovni but sa flesa
rem ==========================================================================
:CHECKLOOP
set "ANS=%1:\Windows\Panther\unattend.xml"
if not exist "%ANS%" exit /b 0
find /i "WINPROV-AUTOUNATTEND" "%ANS%" >nul 2>&1
set "RC1=!errorlevel!"
find /i "<ComputerName>pc1</ComputerName>" "%ANS%" >nul 2>&1
set "RC2=!errorlevel!"
>> "%LOG%" echo Kes odgovora %ANS%: oznaka find=!RC1!, pc1 find=!RC2! (0 = nadjeno, 1 = nije)
if "!RC1!"=="0" set "LOOP=%1:"
if "!RC2!"=="0" set "LOOP=%1:"
if not "!RC1!"=="0" if not "!RC1!"=="1" set "CHECKERR=find.exe nije procitao %ANS% (errorlevel !RC1!)"
if not "!RC2!"=="0" if not "!RC2!"=="1" set "CHECKERR=find.exe nije procitao %ANS% (errorlevel !RC2!)"
exit /b 0

rem ==========================================================================
rem  :WAIT <sekundi> - pauza SAMO ugradjenim komandama (boot.wim nema timeout.exe; ping.exe nije na spisku).
rem  Petlja cita %time% dok ne prodje zadato vreme. Trosi jedno jezgro dok ceka - u WinPE-u nebitno.
rem  Ako %time% nema ocekivani oblik (HH:MM:SS.cc), pauze nema - STOP ostaje STOP, samo bez cekanja.
rem ==========================================================================
:WAIT
set /a "WAIT_END=%1*100"
set "WAIT_BAD="
call :CENTISEC WAIT_START
if defined WAIT_BAD exit /b 0
set /a WAIT_ROUNDS=0
:WAIT_LOOP
set /a WAIT_ROUNDS+=1
rem Kocnica: petlja se zavrsava i kad sat iz nekog razloga stoji
if !WAIT_ROUNDS! GEQ 3000000 exit /b 0
call :CENTISEC WAIT_NOW
if defined WAIT_BAD exit /b 0
set /a "WAIT_DIFF=WAIT_NOW-WAIT_START"
rem Prelaz preko ponoci: dodaj 24 h u stotinkama
if !WAIT_DIFF! LSS 0 set /a "WAIT_DIFF+=8640000"
if !WAIT_DIFF! LSS !WAIT_END! goto WAIT_LOOP
exit /b 0

:CENTISEC
rem %time% (en-US): " 9:46:14.84" -> razmak u 0 -> "09:46:14.84" -> stotinke od ponoci u promenljivu %1.
rem "1%T:~0,2%-100": 109-100 = 9 - bez toga set /a cita "09" kao (neispravan) oktalni broj.
set "T=%time: =0%"
if not "%T:~2,1%"==":" set "WAIT_BAD=1"
if not "%T:~5,1%"==":" set "WAIT_BAD=1"
if defined WAIT_BAD exit /b 0
set /a "%1=(1%T:~0,2%-100)*360000+(1%T:~3,2%-100)*6000+(1%T:~6,2%-100)*100+(1%T:~9,2%-100)"
exit /b 0

rem ==========================================================================
rem  STOP - zapis u log, poruka, 30 s, gasenje; ako gasenje ne uspe - beskonacna petlja
rem ==========================================================================
:STOP_LOOP
set "REASON=Na %LOOP% je vec instalacija sa ovog flesa - racunar je ponovo butovao sa flesa. Izvadi fles i upali racunar."
goto STOP

:STOP_DISK0
set "REASON=Disk 0 nije unutrasnji disk, nego %DISK0%. Izvadi ostale USB diskove ili instaliraj rucno."
goto STOP

:STOP_UNKNOWN
set "REASON=Disk nepoznatog tipa:%UNKNOWN% - mozda ima podatke. Instaliraj rucno i izaberi disk."
goto STOP

:STOP
rem !REASON! / !HINT! (odlozena ekspanzija) - tekst se samo ispise, znaci u njemu se ne izvrsavaju
>> "%LOG%" echo STOP: !REASON!
if defined HINT (>> "%LOG%" echo !HINT!)
>> "%LOG%" echo Racunar se gasi - NISTA nije obrisano.
echo.
echo STOP: !REASON!
if defined HINT echo !HINT!
echo Racunar se gasi za 30 s - NISTA nije obrisano. Log: %LOG%
call :WAIT 30
rem U WinPE-u nema shutdown.exe - gasenje ide preko wpeutil
wpeutil shutdown

rem Zastita NE zavisi od gasenja: Windows Setup posle RunSynchronous komande nastavlja i kad ona vrati gresku,
rem pa skripta NIKAD ne vraca kontrolu Setup-u. RunSynchronous je sinhron - Setup ceka i ne stize do brisanja diska.
:HALT
echo.
echo STOP: !REASON!
if defined HINT echo !HINT!
echo Instalacija je ZAUSTAVLJENA - nista nije obrisano. Iskljuci racunar dugmetom za napajanje.
call :WAIT 60
goto HALT
