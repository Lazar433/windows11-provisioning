Ovde stavi raspakovane mrezne drajvere (.inf + .sys + .cat), svaki paket u svoj podfolder.
Samo sa zvanicnih sajtova (Intel, Realtek, Microsoft Update Catalog) - ne installer .exe, nego INF paket.

Setup.ps1 (sekcija Network) ih instalira preko "pnputil /add-driver ... /subdirs /install" SAMO kad nema
interneta i nijedan fizicki mrezni adapter nije povezan (ili postoji mrezni uredjaj bez drajvera).

Drajveri se ne cuvaju u git-u (.gitignore).
