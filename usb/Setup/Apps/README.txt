Ovde stavi Ninite installer (https://ninite.com - izaberes aplikacije, preuzmes .exe).

Setup.ps1 (sekcija Apps) trazi Ninite*.exe u ovom folderu i podfolderima i pokrece ga SAMO ako je
potpis Valid i potpisnik tacno Ninite (Secure By Design Inc.). Svaki drugi .exe ili .msi se ignorise.
Ninite tokom rada preuzima aplikacije - potreban je internet.

Installeri se ne cuvaju u git-u (.gitignore).
